![REPO](https://img.shields.io/badge/REPO-in%20progress-blueviolet?logoColor=white)

README(W.I.P): [README.md](https://github.com/florianthepro/jellyfin-enhanced-setup/blob/main/README.md)

---
1. go to https://login.tailscale.com 
2. create account/sing in
3. go to https://login.tailscale.com/admin/acls/file
4. add:
```
	"nodeAttrs": [
		{
			"target": ["autogroup:member"],
			"attr":   ["funnel"]
		}
	]
```
5. run on device
```
curl -sSL https://raw.githubusercontent.com/florianthepro/jellyfin-enhanced-setup/main/setup.sh | bash
```
