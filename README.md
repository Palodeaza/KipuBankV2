# Kipu-BankV2

- Versión 2 del contrato original. Se mejoró la seguridad, escalabilidad y trazabilidad mediante la introducción de control de acceso con un rol de propietario (onlyOwner), lo que permite restringir operaciones administrativas críticas.
Además, se añadió soporte para múltiples tokens ERC-20 y una contabilidad interna que diferencia depósitos y retiros según el tipo de activo, usando el address(0) para representar ETH. Se integró también una estructura preparada para trabajar con oráculos ChainLink, con el fin de convertir valores de ETH a USD, y aplicar límites dinámicos. Se otimizaron transferencias y validadciones siguiendo el patrón checks-effects-interactions, junto con eventos y errores personalizados.


- INSTRUCCIONES DE DEPLOY E INTERACCIÓN (desde Remix):
    - Compliar con el compilador Solidity (yo use 0.8.30) y seleccionar el entorno "Injected Provider- Metamask" o billetera de preferencia.
    - En los campos de constructor ingresar la dirección del owner y definir los limites bankCap y perTxWithdrawalLimit en wei.
    - Para interactuar, se pueden usar las funciones deposit(), withdraw(), y las equivalentes ERC-20 directamente desde Remix o Etherscan. El contrato emitirá eventos dependiendo la transacción realizada.


- DECISIONES DE DISEÑO
     - Se eligió un modelo de propietario único para el control de acceso, priorizando simplicidad y seguridad sobre flexibilidad. En un entorno más complejo se podrían usar librerías como AccessControl de OpenZeppelin para definir roles múltiples (por ejemplo, administradores y auditores).
    - La gestión de tokens ERC-20 se resolvió mediante un mapping anidado (balances(token),(user)), lo cual simplifica la contabilidad interna a costa de un ligero incremento en el consumo de gas.
    - Las funciones receive() y fallback() se rediseñaron para redirigir automáticamente a deposit(), garantizando coherencia en la lógica de validación.
Finalmente, se usaron variables constant e immutable donde fue posible para reducir costos de gas y reforzar la inmutabilidad de parámetros críticos.
