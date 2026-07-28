import manifests
import tmux.schema as schema
import tmux.shell as shell

argocd_ns = "argocd"

k = shell.kubernetes_ns(argocd_ns)

sessions = [
  schema.Tmux {
  name = "argocd"
  workdir = "/home/ubuntu/shitcluster2/shitcluster2"
  env = {
    EDITOR = "nvim"
  }
  before = [
  ]

  windows = [
     schema.Window {
        name: "*argocd"
        panes = [
          ["*${k.get} pods"]
          ["make argocd_password"]
        ]
      }
     schema.Window {
        name: "kcl-plugin"
        panes = [
          ["${k.log} --tail=10 -f deployment/argocd-repo-server -c my-plugin"]
          ["${k.exec} -ti deployment/argocd-repo-server -c my-plugin -- /bin/bash"]
        ]
      }
    ]
  }
]
