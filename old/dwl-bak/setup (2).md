![REPO](https://img.shields.io/badge/FOLDER-in%20progress-blueviolet?logoColor=white)

README(W.I.P): [README.md](https://github.com/florianthepro/public/blob/main/jellyfin-enhanced-setup/README.md)

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
curl -sSL https://raw.githubusercontent.com/florianthepro/public/main/jellyfin-enhanced-setup/setup.sh | bash
```
---
to reset (all)
```
curl -sSL https://raw.githubusercontent.com/florianthepro/public/main/jellyfin-enhanced-setup/reset.sh | sudo bash
```
