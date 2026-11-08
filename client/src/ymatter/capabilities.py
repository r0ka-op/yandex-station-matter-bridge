"""Read-only discovery of the Matter capabilities used by ymatter-bridge."""
from __future__ import annotations

from dataclasses import dataclass, field

from .client import COLOR, DESCRIPTOR, LEVEL, ONOFF, MaindClient, MaindProtocolError
from .client import UnsupportedAttributeError

KNOWN_LIGHT_DEVICE_TYPES = frozenset({0x0100, 0x0101, 0x010C, 0x010D})


def _ints(value, name: str) -> tuple[int, ...]:
    if not isinstance(value, list) or any(type(v) is not int or v < 0 for v in value):
        raise MaindProtocolError(f"{name}: expected an array of unsigned integers, got {value!r}")
    return tuple(value)


def _device_types(value) -> tuple[int, ...]:
    if not isinstance(value, list):
        raise MaindProtocolError(f"Descriptor.DeviceTypeList: expected array, got {value!r}")
    result: list[int] = []
    for item in value:
        if not isinstance(item, dict) or type(item.get(0)) is not int or item[0] < 0:
            raise MaindProtocolError(f"Descriptor.DeviceTypeList: invalid entry {item!r}")
        result.append(item[0])
    return tuple(result)


@dataclass(frozen=True)
class EndpointCapabilities:
    node_id: int
    endpoint_id: int
    device_types: tuple[int, ...]
    server_clusters: frozenset[int]
    attributes: dict[int, frozenset[int]] = field(default_factory=dict)
    accepted_commands: dict[int, frozenset[int]] = field(default_factory=dict)
    feature_maps: dict[int, int] = field(default_factory=dict)
    color_temp_min_mireds: int | None = None
    color_temp_max_mireds: int | None = None

    @property
    def is_light(self) -> bool:
        return bool(KNOWN_LIGHT_DEVICE_TYPES.intersection(self.device_types))

    def supports_attribute(self, cluster: int, attribute: int) -> bool:
        return cluster in self.server_clusters and attribute in self.attributes.get(cluster, ())

    def supports_command(self, cluster: int, command: int) -> bool:
        return cluster in self.server_clusters and command in self.accepted_commands.get(cluster, ())

    @property
    def color_temperature_supported(self) -> bool:
        return (self.supports_command(COLOR, 10)
                and self.supports_attribute(COLOR, 7)
                and self.color_temp_min_mireds is not None
                and self.color_temp_max_mireds is not None
                and self.color_temp_min_mireds <= self.color_temp_max_mireds)


def _optional_read(client: MaindClient, node: int, endpoint: int, cluster: int, attribute: int):
    try:
        return client.read(node, endpoint, cluster, attribute)
    except UnsupportedAttributeError:
        return None


def discover_endpoint_capabilities(client: MaindClient, node: int,
                                   endpoint: int) -> EndpointCapabilities:
    device_types = _device_types(client.read(node, endpoint, DESCRIPTOR, 0))
    server_clusters = frozenset(_ints(client.read(node, endpoint, DESCRIPTOR, 1),
                                      "Descriptor.ServerList"))
    attributes: dict[int, frozenset[int]] = {}
    accepted: dict[int, frozenset[int]] = {}
    features: dict[int, int] = {}
    for cluster in (ONOFF, LEVEL, COLOR):
        if cluster not in server_clusters:
            continue
        av = _optional_read(client, node, endpoint, cluster, 0xFFFB)
        cv = _optional_read(client, node, endpoint, cluster, 0xFFF9)
        fv = _optional_read(client, node, endpoint, cluster, 0xFFFC)
        if av is not None:
            attributes[cluster] = frozenset(_ints(av, f"{cluster}.AttributeList"))
        if cv is not None:
            accepted[cluster] = frozenset(_ints(cv, f"{cluster}.AcceptedCommandList"))
        if fv is not None:
            if type(fv) is not int or fv < 0:
                raise MaindProtocolError(f"{cluster}.FeatureMap: expected unsigned integer")
            features[cluster] = fv

    ct_min = ct_max = None
    if COLOR in server_clusters and 0x400B in attributes.get(COLOR, ()):
        ct_min = client.read(node, endpoint, COLOR, 0x400B)
    if COLOR in server_clusters and 0x400C in attributes.get(COLOR, ()):
        ct_max = client.read(node, endpoint, COLOR, 0x400C)
    for name, value in (("ColorTempPhysicalMinMireds", ct_min),
                        ("ColorTempPhysicalMaxMireds", ct_max)):
        if value is not None and (type(value) is not int or value <= 0):
            raise MaindProtocolError(f"{name}: expected positive unsigned integer")

    return EndpointCapabilities(node, endpoint, device_types, server_clusters,
                                attributes, accepted, features, ct_min, ct_max)


__all__ = ["EndpointCapabilities", "KNOWN_LIGHT_DEVICE_TYPES",
           "discover_endpoint_capabilities"]
