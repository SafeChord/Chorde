# K3han Ingress 總覽

本系統以兩個獨立的 IngressClass 通道「`nginx-private`」與「`nginx-public`」構建 SafeZone 的對內與對外網路邊界。兩者功能與存取方式明確劃分，作為後續所有外部接入與內部模組通訊的基礎。

---

## 1️⃣ ingress-private (`IngressClass: nginx-private`)

| 項目 | 說明 |
| --- | ------------------------------------------------------------------------------------------- |
| 🌟 功能定位 | 內部專用通道，代理 prometheus、 grafana、argocd |
| 🛠 部署位置 | control-plane 節點（Contabo `ct-serv-jp`）|
| 🌐 網路模式 | 使用 `hostNetwork: true`，續接 Tailscale VPN 網卡（100.x.x.x）|
| 🔐 安全性 | 僅能由 overlay VPN 內節點或 Cloudflare tunnel 存取 localhost，完全不曝露於公網 |
| 🚪 存取方式 | Cloudflare Tunnel 指向 Tailscale IP ，使用 DNS hostname ：`k3han.omh.idv.tw` |

---

## 2️⃣ ingress-public (`IngressClass: nginx-public`)

| 項目 | 說明 |
| --- |--------------------------------------------------------------------------------------------- |
| 🌟 功能定位  | 對外公開服務的唯一入口，處理 UI、API、用戶互動，也包括 CLI relay 內部 OAuth 簽証流程|
| 🛠 部署位置 | agent 節點（GCE VM instance `gce-agent-tw`）|
| 🌐 網路模式  | 使用 `hostPort: 80/443`，續接 GCP 公網 IP|
| 🔐 安全性 | 啟用限速、隱藏 headers 等 basic hardening |
| 🔐 SSL 簽署 | Ingress 本身未啟用 TLS。TLS 由 Cloudflare proxy 結等通道轉導、DNS CNAME 等設定轉接 |
| 🚪存取方式 | 由 Cloudflare proxy 結等通道轉導、DNS CNAME 等設定轉接 |

---

## ✅ 使用建議與維運原則

| 通道 | 適用情境 | 使用建議 |
| --------------- | ---------------------------- | ----------------------------------------- |
| ingress-private | 內部各項服務（如 Grafana、ArgoCD 等） | 用於 VPN 內節點或 cloudflared tunnel 存取 |
| ingress-public  | 外部存取服務（如 SAFEZONE-Dashboard、SAFEZONE-CLI 等） | 請給予合法 Host header，優先給 Cloudflare Proxy 認證 |

---
## 🧪 Ingress 通道隔離測試紀錄表

| 測試來源 | 網路狀態 | URL | 預期行為 | 實際 HTTP Code | 備註 |
|---------|----------|-----|---------|----------------|------|
| ct-serv-jp | tailscale | http://localhost/nginx | ✅ 回傳 nginx-private 內容 | 200 | |
| ct-serv-jp | tailscale | http://gce-agent-tw-ip/echo | ✅ 正常回傳 echo | 200 | |
| ct-serv-jp | tailscale | http://gce-agent-tw-vpn-ip/echo | ✅ 正常回傳 echo | 200 | |
| gce-agent-tw | tailscale | http://localhost/echo | ✅ 回傳 nginx-public 內容 | 200 | |
| gce-agent-tw | tailscale | http://ct-serv-jp-ip/nginx | ❌ 不應該觸發 private backend | null, curl Couldn't connect to server | 內部服務不應該可以透過公網 IP 存取 |
| gce-agent-tw | tailscale | http://ct-serv-jp-vpn-ip/nginx | ✅ 回傳 nginx-private 內容 | 200 | |
| gce-agent-tw | tailscale | http://localhost/nginx | ❌ 不應該觸發 private backend | 404 | 測試 class 隔離正確性 |
| HP Dev 無痕 | 公網直連 | http://k3han.omh.idv.tw/nginx | ❌ 預期失敗（若 Tunnel 限制來源）| 401  | 進入登入畫面，沒有簽署不能存取 |
| HP Dev 無痕 | 公網直連 | http://www.omh.idv.tw/echo | ✅ 可觸發 ingress-public | 200 | |
| HP Dev 無痕 | 公網直連 | http://www.omh.idv.tw/nginx | ❌ 不應該觸發 private backend | 404 | 測試誤導防線 |
| HP Dev 無痕 + warp | cloudflare tunnel | http://k3han.omh.idv.tw/nginx | ✅ 可觸發 ingress-private | 200 | |
| HP Dev 無痕 + warp | cloudflare tunnel | http://www.omh.idv.tw/echo | ✅ 可觸發 ingress-public | 200 | |
| HP Dev 無痕 + warp | cloudflare tunnel | http://www.omh.idv.tw/nginx | ❌ 不應該觸發 private backend |404 | 防止誤導 class 行為 |
- cloudflare tunnel 網路連線狀態為擴張公網能力，類似 VPN
- 測試用部屬文件請參考 testing/