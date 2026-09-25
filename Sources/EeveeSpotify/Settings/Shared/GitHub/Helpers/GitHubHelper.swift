import Foundation

struct GitHubHelper {
    private let apiUrl = "https://api.github.com"
    private let decoder = JSONDecoder()
    
    static let shared = GitHubHelper()
    
    init() {
        decoder.keyDecodingStrategy = .convertFromSnakeCase
    }
    
    private func perform(_ path: String) async throws -> Data {
        let url = URL(string: "\(apiUrl)\(path)")!
        writeDebugLog("[GitHub] GET \(path)")
        let (data, _) = try await URLSession.shared.data(from: url)
        writeDebugLog("[GitHub] \(path) -> \(data.count) bytes")
        return data
    }
    
    /// 版本检查的数据源。**写死本仓库**（与 `EeveeSpotifyReborn-ng` 的做法一致）：
    /// 版本检查问的是"我这个 fork 有没有新版"，跟着构建机的 git remote 漂移没有意义
    /// （换分支/改 remote 就会去查别人的 release）。
    ///
    /// ⚠️ 本仓库若没有 tag 化的 release，这里会 404 —— 那是**预期内**的：
    /// `EeveeSettingsVersionView.loadVersion()` 会把失败当成"没有新版本"，
    /// 界面只是不提示更新，不会卡在转圈上（见那里的 15 秒超时与兜底）。
    func getLatestRelease() async throws -> GitHubRelease {
        let data = try await perform("/repos/zbzxbg/EeveeSpotify-ng-latest/releases/latest")
        return try decoder.decode(GitHubRelease.self, from: data)
    }
    
    func getUser(_ username: String) async throws -> GitHubUser {
        let data = try await perform("/users/\(username)")
        return try decoder.decode(GitHubUser.self, from: data)
    }
    
    func getContributors() async throws -> [GitHubUser] {
        let data = try await perform("/repos/\(EeveeSpotify.repoSlug)/contributors")
        return try decoder.decode([GitHubUser].self, from: data)
    }
    
    func getEeveeContributorSections() async throws -> [EeveeContributorSection] {
        let (data, _) = try await URLSession.shared.data(
            from: URL(
                string: "https://raw.githubusercontent.com/\(EeveeSpotify.repoSlug)/refs/heads/\(GeneratedConfig.branchName)/contributors.json"
            )!
        )
        return try decoder.decode([EeveeContributorSection].self, from: data)
    }
}
