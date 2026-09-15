import SwiftUI
import SwiftData

@main
struct PayUpApp: App {
    let container: ModelContainer

    init() {
        let schema = Schema([
            Player.self, FineType.self, Fine.self, Match.self,
            Team.self, TeamMember.self
        ])
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
            RootView()
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
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
