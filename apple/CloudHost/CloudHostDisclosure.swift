import Foundation

/// What "My Server" does over the network, shown before setup and in the data
/// use notice. Every item matches the code: SSH and deployment in
/// core/cloudhost, the test in core/libbox/cloud_host.go
/// (lineLatencyTestURL, exitTraceURL, throughputURL, throughputLimit).
enum CloudHostDisclosure {
    static func sshAndInstall(_ zh: Bool) -> String {
        zh ? "只有你使用「我的云主机」时，XDial 才会用你填写的账号经 SSH 登录你的服务器；密码和私钥只在这次设置的内存里使用，不保存，也不写进日志。你确认改动后，服务器会从 sing-box 官方软件源（deb.sagernet.org）下载并安装 sing-box（如果还没有），并新建一个独立的代理服务。"
           : "Only when you use My Server does XDial sign in to your server over SSH with the account you enter; the password and key are used in memory for that setup only and are never saved or logged. After you confirm the changes, the server downloads and installs sing-box from its official repository (deb.sagernet.org) if needed, and adds a separate proxy service."
    }

    static func test(_ zh: Bool) -> String {
        zh ? "部署后的测试经这台服务器发出三项 HTTPS 请求：访问 www.gstatic.com 检查能否连通（几十字节）；访问 Cloudflare 的 1.1.1.1 查询出口 IP（不到 1 KB）；从 speed.cloudflare.com 下载测速（最多约 10 MB、最长 12 秒）。每次「重新测试」都会再做一遍。"
           : "After setup, the test makes three HTTPS requests through the server: www.gstatic.com to check that it works (a few dozen bytes), Cloudflare's 1.1.1.1 to look up the exit IP (under 1 KB), and a download from speed.cloudflare.com to measure speed (up to about 10 MB, at most 12 seconds). Each Test Again repeats them."
    }

    static func visibility(_ zh: Bool) -> String {
        zh ? "这些服务看到的是你服务器的 IP 地址、请求时间和所访问的地址；请求里没有你的 SSH 账号、密码或线路密钥。测速会同时用掉服务器和这台设备的流量。"
           : "These services see your server's IP address, the time and the address requested; the requests carry no SSH account, password or line key. The speed test uses data on both the server and this device."
    }

    static func points(_ zh: Bool) -> [String] { [sshAndInstall(zh), test(zh), visibility(zh)] }

    static func title(_ zh: Bool) -> String { zh ? "我的云主机（只在你使用时）" : "My Server (only when you use it)" }
}
