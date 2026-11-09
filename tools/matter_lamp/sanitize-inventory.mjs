#!/usr/bin/env node
import { readFileSync, writeFileSync } from "node:fs";

const [input, output] = process.argv.slice(2);
if (!input || !output) throw new Error("usage: sanitize-inventory.mjs INPUT OUTPUT");
const source = JSON.parse(readFileSync(input, "utf8"));

// Only operational lighting values are publishable. Endpoint-0 identity,
// networking, ACL/fabric data and all vendor attribute values are omitted.
const publishableStandardValues = new Set([3, 4, 6, 8, 29, 80, 768]);
const result = {
  schema: 1,
  collected_at: source.collected_at,
  completed_at: source.completed_at,
  node_id: source.node_id,
  classification: "redacted single-path inventory; no credentials, network data, identities or raw persistence",
  endpoints: {},
  failures: source.failures,
};

for (const [endpointId, endpoint] of Object.entries(source.endpoints)) {
  const outputEndpoint = {
    descriptor: endpoint.descriptor,
    clusters: {},
  };
  for (const [clusterId, cluster] of Object.entries(endpoint.clusters)) {
    const numericCluster = Number(clusterId);
    const outputCluster = { globals: cluster.globals };
    if (Number(endpointId) === 1 && publishableStandardValues.has(numericCluster)) {
      outputCluster.attributes = cluster.attributes;
    } else {
      outputCluster.attributes = Object.fromEntries(
        Object.keys(cluster.attributes).map(attributeId => [attributeId, { redacted: true }]),
      );
    }
    outputEndpoint.clusters[clusterId] = outputCluster;
  }
  result.endpoints[endpointId] = outputEndpoint;
}

writeFileSync(output, JSON.stringify(result, null, 2), "utf8");
console.log(JSON.stringify({ endpoints: Object.keys(result.endpoints).length, output }));
