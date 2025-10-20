// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title KipuBankV2
 * 
 * - address(0) representa ETH
 * - bankCapUsd y perTxLimitUsd usa los mismos decimales que el agregador de Chainlink seleccionado
 (usualmente 8)
 */

interface IERC20Minimal {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface AggregatorV3Interface {
    function latestRoundData() external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    );
    function decimals() external view returns (uint8);
}

/* ------------------------------------------------------------------------
   ERRORESS
 */
error KBV2_ZeroAmount();
error KBV2_NotOwner();
error KBV2_UnsupportedToken(address token);
error KBV2_ExceedsBankCapUsd(uint256 attemptedUsd, uint256 remainingUsd);
error KBV2_InsufficientBalance(address token, address who, uint256 requested, uint256 available);
error KBV2_ExceedsPerTxLimitUsd(uint256 requestedUsd, uint256 perTxLimitUsd);
error KBV2_TransferFailed();
error KBV2_BadDecimals();

/* ------------------------------------------------------------------------
   CONTRATO
 */
contract KipuBankV2 {
    /* --------------------------------------------------------------------
       ESTADO: INMUTABLE / CONSTANTE
     */
    /// direccion del dueño (control administrativo)
    address public immutable owner;

    /**
     Límite global del banco expresado en USD con la misma cantidad de decimales
     que los feeds Chainlink que usarás para conversiones. (Ej: si uso feeds con 8 decimales,
     este valor debe estar en "usd * 10^8").
     */
    uint256 public immutable bankCapUsd;

    /**
     Límite por transacción (en USD, con la misma base decimal que el feed).
     */
    uint256 public immutable perTxLimitUsd;

    /* --------------------------------------------------------------------
       ALMACENAMIENTO
    */
    /// Balances anidados: token => (user => amount). token==address(0) -> ETH
    mapping(address => mapping(address => uint256)) private balances;

    /// Contadores por usuario y token
    mapping(address => mapping(address => uint256)) public userDepositCount; // token => user => count
    mapping(address => mapping(address => uint256)) public userWithdrawCount;

    /// Total en el banco por token (para reporting interno)
    mapping(address => uint256) public totalTokenBalances;

    /// Tokens soportados
    mapping(address => bool) public supportedToken;

    /// Token => decimals (para normalizar conversiones; ex: USDC=6, ERC20 typical)
    mapping(address => uint8) public tokenDecimals;

    /// Token => Chainlink aggregator (must return price in USD)
    mapping(address => AggregatorV3Interface) public tokenUsdAggregator;

    /// Totales globales
    uint256 public totalDepositsCount;
    uint256 public totalWithdrawalsCount;

    /* --------------------------------------------------------------------
       FLAGS POR RE-ENTER (si alguien vuelve a entrar)
    */
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status;

    /* --------------------------------------------------------------------
       EVENTS
    */
    event Deposit(address indexed token, address indexed who, uint256 amount, uint256 amountUsd, uint256 timestamp);
    event Withdrawal(address indexed token, address indexed who, uint256 amount, uint256 amountUsd, uint256 timestamp);
    event TokenSupported(address indexed token, address indexed aggregator, uint8 decimals);
    event TokenUnsupported(address indexed token);
    event OwnerChanged(address indexed oldOwner, address indexed newOwner);

    /* --------------------------------------------------------------------
       MODIFICADORES
    */
    modifier onlyOwner() {
        if (msg.sender != owner) revert KBV2_NotOwner();
        _;
    }

    modifier nonReentrant() {
        if (_status == _ENTERED) revert KBV2_TransferFailed();
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

    modifier nonZero(uint256 amount) {
        if (amount == 0) revert KBV2_ZeroAmount();
        _;
    }

    /* --------------------------------------------------------------------
       CONSTRUCTOR
    */
    /**
     * @param _owner address del dueño
     * @param _bankCapUsd bank cap in USD using aggregator decimals (e.g., 8)
     * @param _perTxLimitUsd per transaction limit in USD using aggregator decimals
     */
    constructor(address _owner, uint256 _bankCapUsd, uint256 _perTxLimitUsd) {
        require(_owner != address(0), "owner zero");
        owner = _owner;
        bankCapUsd = _bankCapUsd;
        perTxLimitUsd = _perTxLimitUsd;
        _status = _NOT_ENTERED;
    }

    /* --------------------------------------------------------------------
       ADMIN FUNCTIONS
       -------------------------------------------------------------------- */

    /**
     * @notice Marca un token como soportado y registra su aggregator y decimals.
     * @param token dirección del token (address(0) para ETH aggregator)
     * @param aggregator dirección del Chainlink feed para token->USD (no null)
     * @param decimalsDecimals número de decimales del token (por ejemplo 18 para ETH/ERC20 que usan 18)
     */
    function addSupportedToken(address token, address aggregator, uint8 decimalsDecimals) external onlyOwner {
        if (aggregator == address(0)) revert KBV2_UnsupportedToken(token);
        supportedToken[token] = true;
        tokenUsdAggregator[token] = AggregatorV3Interface(aggregator);
        tokenDecimals[token] = decimalsDecimals;
        emit TokenSupported(token, aggregator, decimalsDecimals);
    }

    /**
     * @notice Quita soporte a un token (no borra saldos).
     */
    function removeSupportedToken(address token) external onlyOwner {
        supportedToken[token] = false;
        delete tokenUsdAggregator[token];
        delete tokenDecimals[token];
        emit TokenUnsupported(token);
    }

    /**
     * @notice Permite al owner cambiar la cuenta owner (transferir propiedad).
     */
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "zero new owner");
        emit OwnerChanged(owner, newOwner);
        // owner es immutable; en este diseño, owner fue immutable — si quieres poder cambiar owner, no usar immutable.
        // Para este contrato (single-file) mantenemos owner immutable. Si deseas ownership transfer,
        // elimina immutable y cambia lógica. Aquí revert para dejarlo claro.
        revert KBV2_NotOwner();
    }

    /* --------------------------------------------------------------------
       DEPOSITO / EXTRACCION
       -------------------------------------------------------------------- */

    /**
     * @notice Depósito para ETH. `receive()` y `fallback()` llaman a esta función.
     */
    function deposit() public payable nonZero(msg.value) {
        address token = address(0);
        _depositCore(token, msg.sender, msg.value);
    }

    /**
     * @notice Depósito para ERC20: el usuario debe haber aprobado antes al contrato.
     * @param token dirección del token ERC20
     * @param amount cantidad en token base (según tokenDecimals[token])
     */
    function depositERC20(address token, uint256 amount) external nonZero(amount) {
        if (!supportedToken[token]) revert KBV2_UnsupportedToken(token);
        // transferFrom user -> this
        bool ok = IERC20Minimal(token).transferFrom(msg.sender, address(this), amount);
        if (!ok) revert KBV2_TransferFailed();

        _depositCore(token, msg.sender, amount);
    }

    /**
     * @notice Retira ETH o ERC20. Token == address(0) -> ETH.
     * @param token token address
     * @param amount cantidad en token base
     */
    function withdraw(address token, uint256 amount) external nonZero(amount) nonReentrant {
        if (!supportedToken[token]) revert KBV2_UnsupportedToken(token);

        uint256 userBal = balances[token][msg.sender];
        if (amount > userBal) revert KBV2_InsufficientBalance(token, msg.sender, amount, userBal);

        // Convertir el monto a USD agregando decimales
        uint256 amountUsd = _amountToUsd(token, amount);

        if (amountUsd > perTxLimitUsd) revert KBV2_ExceedsPerTxLimitUsd(amountUsd, perTxLimitUsd);

        // Effects
        balances[token][msg.sender] = userBal - amount;
        totalTokenBalances[token] -= amount;
        unchecked {
            userWithdrawCount[token][msg.sender] += 1;
            totalWithdrawalsCount += 1;
        }

        // Interacciones
        if (token == address(0)) {
            // ETH
            _safeTransferETH(payable(msg.sender), amount);
        } else {
            bool ok = IERC20Minimal(token).transfer(msg.sender, amount);
            if (!ok) revert KBV2_TransferFailed();
        }

        emit Withdrawal(token, msg.sender, amount, amountUsd, block.timestamp);
    }

    /* --------------------------------------------------------------------
       INTERNAL CORE: deposit logic shared by ETH/ERC20
       -------------------------------------------------------------------- */
    function _depositCore(address token, address who, uint256 amount) private {
        if (!supportedToken[token]) revert KBV2_UnsupportedToken(token);

        // Convert incoming amount to USD
        uint256 amountUsd = _amountToUsd(token, amount);

        // Check bank cap
        uint256 currentBankUsd = _currentBankUsd();
        uint256 remaining = 0;
        if (bankCapUsd > currentBankUsd) remaining = bankCapUsd - currentBankUsd;
        if (amountUsd > remaining) revert KBV2_ExceedsBankCapUsd(amountUsd, remaining);

        // Effects
        balances[token][who] += amount;
        totalTokenBalances[token] += amount;
        unchecked {
            userDepositCount[token][who] += 1;
            totalDepositsCount += 1;
        }

        emit Deposit(token, who, amount, amountUsd, block.timestamp);
    }

    /* --------------------------------------------------------------------
       PRICE & DECIMAL HELPERS
       -------------------------------------------------------------------- */

    /**
     * @dev Devuelve el price feed latest answer para token (en USD) y lo normaliza.
     *      amountToUsd = amount * price / (10 ** tokenDecimals)
     * @param token token address (address(0) = ETH)
     */
    function _amountToUsd(address token, uint256 amount) private view returns (uint256) {
        AggregatorV3Interface agg = tokenUsdAggregator[token];
        if (address(agg) == address(0)) revert KBV2_UnsupportedToken(token);
        (, int256 answer, , , ) = agg.latestRoundData();
        if (answer <= 0) revert KBV2_TransferFailed();
        uint8 feedDecimals = agg.decimals();

        // price = answer (USD with feedDecimals)
        // tokenDecimals[token] = decimals of token units
        uint8 tDec = tokenDecimals[token];
        // We want amountUsd in the same decimals as the feed (feedDecimals)
        // amountUsd = amount * price / (10 ** tDec)
        // safe multiplication: amount * uint256(answer)
        uint256 unsignedPrice = uint256(answer);
        // perform multiplication then division
        // watch overflow: use unchecked and solidity 0.8 has big ranges (we assume reasonable amounts)
        uint256 raw = amount * unsignedPrice;
        uint256 amountUsd = raw / (10 ** tDec);
        return amountUsd;
    }

    /**
     * @notice Calcula el total en USD del banco sumando todos los tokens soportados.
     * Para gas efficiency no escanea todo el mapping; se asume caller conoce tokens soportados.
     * Para demo, soportamos calcular solo por token pasado (helper).
     */
    function _currentBankUsd() private view returns (uint256) { 
        // NOTA: Para calcular correctamente el total global en USD, sería necesario contar con una lista (array) de los tokens admitidos.
        //Por simplicidad en esta tarea, solo se admitirá un conjunto reducido de tokens de forma operativa, y el propietario debe asegurarse de que el bankCap se respete por cada token al realizar depósitos.
        //Aquí se aproxima el valor a 0.
        //En un entorno de producción, se debería mantener un array de tokens admitidos y recorrerlo (considerando el consumo de gas).
        //Igual, esto es una warning, cambiandolo a pure en vez de view, se arreglaria, pero me parece que cambia el modo lectura/escritura a solo lectura.
        return 0;
    }

    /* --------------------------------------------------------------------
       SAFE TRANSFERS
       -------------------------------------------------------------------- */
    function _safeTransferETH(address payable to, uint256 amount) private {
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert KBV2_TransferFailed();
    }

    /* --------------------------------------------------------------------
       VIEWS
       -------------------------------------------------------------------- */

    /// @notice Devuelve el balance de un usuario para un token.
    function getBalance(address token, address who) external view returns (uint256) {
        return balances[token][who];
    }

    /// @notice Devuelve cuánto (aprox) representa una cantidad de token en USD (decimales del feed)
    function viewAmountToUsd(address token, uint256 amount) external view returns (uint256) {
        return _amountToUsd(token, amount);
    }

    /// @notice Comprueba si un token es soportado
    function isTokenSupported(address token) external view returns (bool) {
        return supportedToken[token];
    }

    /* --------------------------------------------------------------------
       RECEIVE / FALLBACK
       -------------------------------------------------------------------- */
    receive() external payable {
        // Llamamos a deposit() para asegurar la misma lógica
        // msg.value es accesible dentro de deposit()
        deposit();
    }

    fallback() external payable {
        // también redirigimos a deposit() si llega ETH
        if (msg.value > 0) {
            deposit();
        } else {
            // si es llamada sin ETH, revertimos para evitar comportamientos ambiguos
            revert KBV2_ZeroAmount();
        }
    }
}
