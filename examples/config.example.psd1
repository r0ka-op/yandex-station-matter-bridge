@{
    # SSH alias from ~/.ssh/config. Root access is required by the runtime controller.
    SshAlias         = 'station-root'

    # Documentation-only TEST-NET addresses. Replace both values locally.
    StationIPv4      = '192.0.2.10'
    StationIPv6      = '2001:db8::10'

    # Matter operational Node ID is installation-specific. Decimal and 0x notation work.
    MatterNodeId     = [UInt64]0x1234
    MatterEndpointId = [UInt16]1
}
