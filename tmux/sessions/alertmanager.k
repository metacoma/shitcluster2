import manifests
import tmux.schema as schema
import tmux.shell as shell
import gitops.workloads.config as config

_config = config.config
monitoring = _config.monitoring

k = shell.kubernetes_ns(monitoring.namespace)

sessions = [
  schema.Tmux {
  name = "alertmanager"
  workdir = "/home/ubuntu/shitcluster2/shitcluster2"

  windows = [
     schema.Window {
        name: "*alertmanager"
        panes = [
          ["*${k.exec} -ti statefulset/alertmanager -- /bin/sh"]
          ["*${k.log} statefulset/alertmanager"]
        ]
      }
    ]
  }
]
