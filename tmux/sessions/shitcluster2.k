import tmux.schema as schema
import yaml
import file

name = "shitcluster2"

domain = "mansion.shitcluster.io"

mgmt_domain = "mgmt.${domain}"
private_domain = "private.${domain}"

cluster_hosts = yaml.decode_all(file.read("../ansible/inventory.yml"))[0]

etcd_hosts = list(cluster_hosts.etcd.hosts)

etcd_access_ips = [
    cluster_hosts["all"]["hosts"][h]["access_ip"]
    for h in etcd_hosts
]

etcd_port = 2379

make_etcd_endpoinds = lambda hosts: [str] -> str {
  ",".join(["https://" + ip + ":${etcd_port}" for ip in etcd_access_ips])
}

session = schema.Tmux {
  name = name
  workdir = "~/shitcluster2/repo"
  windows = [
     schema.Window {
        name: "*gitops"
        panes = [
          ["*nvim"]
          ["kubectl get nodes"]
        ]
      }
     schema.Window {
        name: "etcd"
        env.SSH_AUTH_SOCK = ""
        panes = [
          [
            "ssh ${host_name}.${mgmt_domain}",
            """export ETCDCTL_API=3
export ETCD_ENDPOINTS="${make_etcd_endpoinds(etcd_access_ips)}"
export ETCD_CA="/etc/ssl/etcd/ssl/ca.pem"
export ETCD_CERT="/etc/ssl/etcd/ssl/node-${host_name}.pem"
export ETCD_KEY="/etc/ssl/etcd/ssl/node-${host_name}-key.pem"
"""
            """watch sudo etcdctl \
  --endpoints="$ETCD_ENDPOINTS" \
  --cacert="$ETCD_CA" \
  --cert="$ETCD_CERT" \
  --key="$ETCD_KEY" \
  endpoint status -w table
            """

          ]
          for host_name,host in cluster_hosts.etcd.hosts
        ]
      }
    ] + [
      schema.Window {
      name: host_name
      env.SSH_AUTH_SOCK = ""
      panes = [
        ["*ping ${name}.${mgmt_domain}"]
        [
          """
          while :; do
              ssh ${name}.${mgmt_domain}
              sleep 1
              echo .....
          done
          """
        ]
      ]
    } for host_name,host in cluster_hosts.all.hosts]
}
