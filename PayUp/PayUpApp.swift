import SwiftUI
import SwiftData

@main
struct PayUpApp: App {
    let container: ModelContainer

    /// Owned here rather than in RootView so the scene's URL handler can reach
    /// it — reset links arrive through `.onOpenURL`.
    @State private var auth = AuthService(client: SupabaseClientProvider.shared)

    init() {
        // Only the team layer is local now; everything else lives in Supabase.
        let schema = Schema([Team.self, TeamMember.self])
        do {
            container = try ModelContainer(for: schema)
        } catch {
            // A store we can't open is unrecoverable; in-memory keeps the app usable.
            container = try! ModelContainer(
                for: schema,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
        }
        Appearance.apply()
    }

    var body: some Scene {
        WindowGroup {
            RootView(auth: auth)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                // Delivered for both a cold start (the link launched the app)
                // and a warm one. On a cold start it can land before or after
                // restore() finishes; AuthService makes either order end on the
                // new-password screen.
                .onOpenURL { url in
                    Task { await auth.handle(url) }
                }
        }
        .modelContainer(container)
    }
}

enum Appearance {
    static func apply() {
        #if os(iOS)
        let beige = UIColor(Theme.beige)
        let bg = UIColor(Theme.bg)

        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = bg
        nav.shadowColor = .clear
        nav.titleTextAttributes = [.foregroundColor: beige]
        nav.largeTitleTextAttributes = [
            .foregroundColor: beige,
            .font: UIFont.systemFont(ofSize: 34, weight: .bold)
        ]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav

        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = bg
        tab.shadowColor = UIColor(Theme.surfaceHi)
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
        #endif
    }
}
