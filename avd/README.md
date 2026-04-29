# AVD Capacity Planning

The CCTS Platform team does not have access to the AVD control plane for the CDO AVD nodes used extensively by Defra suppliers.

To perform a capacity review, the CCTS Platform team currently raises a manual request with CCoE for raw data. That data is reviewed, recommendations are made, and where appropriate configuration is updated.

Cloudability is also reviewed frequently. Though Cloudability is utitlised in Defra as a financial reporting tool, the granularity is sufficient to spot infrastructure issues, e.g. Compute not scaling down as planned.

## Point-in-time utilisation assessment

### `assess-vms-powered-on.ps1`

AVD can autoscale by powering on previously deployed AVD hosts in a given host pool. The AVD control plane has access to  both start and stop VMs based on usage. This is the mechanism that forms part of the CCoE deployment pattern for AVD.

If there are point-in-time capacity concerns, the `assess-vms-powered-on.ps1` script can be run to provide a rudimentary view of current capacity.

At the time of writing:

- The max pool size is 8 servers.
- The maximum number of connections per server is 20.

There are two Host Pools to support Blue/Green deployments (denoted by "B" and "G" in the naming). In normal operation only Blue or Green nodes should be dployed. Sometimes storage is left in place by a Blue/Green switch over. This is incorrect and should be reported as an incident.

The script `assess-vms-powered-on.ps1` pings hosts to determine whether each is online. It is typically run from within the environment itself.

Servers are scaled down when there is capacity and there are no active connections on a given server.

The following settings are observed:

- Sessions are forcefully disconnected after 1 hour of inactivity.
- Sessions are forcefully logged off after 1 hour of being disconnected.

Once all users are logged off, the host will be powered down by the AVD platform.

### Script intent

The script provides a quick view of reachability from within the service. It is **not** suited to scheduled runs or trend gathering. Rich capacity-planning data is available natively in AVD; that is not accessible to the CCTS Platform team today, so strategies such as multi-homing Log Analytics should be considered instead.
