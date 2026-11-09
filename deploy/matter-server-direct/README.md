# YNDX-00560 direct invoke fallback

This image retains the pinned Matter.js Server 1.5.5 runtime and only relaxes the
local endpoint-model guard for a single configured operational node. The normal
Matter command schema conversion, CASE session, Interaction Model invoke,
timeouts and response status handling remain unchanged.

The fallback is fail-closed unless `YNDX00560_DIRECT_INVOKE_NODE_ID` exactly
matches the target. It permits only endpoint 1 and these standard commands:

- OnOff: `off`, `on`;
- LevelControl: `moveToLevel`;
- ColorControl: `moveToHueAndSaturation`, `moveToColorTemperature`.

It does not expose arbitrary invokes, writes, fabric, ACL, commissioning or
vendor-specific commands.
