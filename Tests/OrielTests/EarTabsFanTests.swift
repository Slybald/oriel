import XCTest
@testable import Oriel

/// L'éventail des intercalaires (logique pure) : tranche montrée par chaque rang, ordre de la pile, ouverture au survol et
/// stabilité des zones (rien ne change de cible sous une souris immobile, leçon de la barre d'onglets 1.2.1).
final class EarTabsFanTests: XCTestCase {
    private let notch = CGSize(width: 185, height: 32)

    private func tabs(_ count: Int, alertAt alert: Int? = nil) -> [EarTab] {
        EarTabs.tabs(claude: .none, claudeEars: nil, modules: (0..<count).map {
            ModuleEarsEntry(id: "m\($0)", ears: ModuleEars(symbol: "circle", text: "\($0 + 10)", priority: 100 - $0,
                                                           alert: $0 == alert))
        }, showEars: true)
    }

    private func layout(_ count: Int, mode: EarTabsMode = .visible, alertAt alert: Int? = nil) -> EarTabsLayout {
        EarTabsLayout(tabs: tabs(count, alertAt: alert), notch: notch, mode: mode)
    }

    // MARK: - Tranches

    /// Toujours visibles : le premier de chaque côté montre icône et information, chacun des suivants une tranche
    /// d'icône de largeur régulière : l'éventail a un décalage régulier.
    func testVisibleFanShowsFirstTabInFullThenRegularSlices() {
        let fan = layout(6)
        for side in [fan.left, fan.right] {
            XCTAssertEqual(side[0].width, side[0].tab.restWidth)
            XCTAssertTrue(side[0].showsInfo)
            for item in side.dropFirst() {
                XCTAssertEqual(item.width, EarTabs.sliceWidth, "\(item.id) : une tranche d'icône")
                XCTAssertFalse(item.showsInfo, "\(item.id) : l'information reste sous le précédent")
                XCTAssertGreaterThanOrEqual(item.width, 2 * EarTabs.padding + EarTabs.iconWidth, "l'icône tient entière")
            }
        }
    }

    /// Chaque tranche commence où finit celle qui est plus près de la notch, la première contre la notch : l'éventail
    /// se lit comme une pile de cartes décalées, du plus prioritaire contre la notch vers l'extérieur.
    func testSlicesStartWhereTheCloserOneEnds() {
        let fan = layout(6)
        for side in [fan.left, fan.right] {
            var edge = notch.width / 2
            for (rank, item) in side.enumerated() {
                XCTAssertEqual(item.rank, rank)
                XCTAssertEqual(item.inner, edge, accuracy: 0.001)
                edge += item.width
            }
        }
        XCTAssertEqual(fan.reach, fan.left.last!.inner + fan.left.last!.width)
    }

    /// Rétractés : l'éventail est serré, une languette par intercalaire ; une alerte reste déployée, même au milieu.
    func testRetractedFanIsTightButAnAlertStaysDeployed() {
        let tight = layout(6, mode: .retracted)
        XCTAssertTrue(tight.items.allSatisfy { $0.width == EarTabs.sliverWidth })
        XCTAssertLessThan(tight.reach, layout(6, mode: .visible).reach)

        // m2 est le deuxième de la pile gauche (m0, m2, m4) : une alerte y garde icône et information.
        let withAlert = layout(6, mode: .retracted, alertAt: 2)
        XCTAssertEqual(withAlert.item("m2")?.rank, 1)
        XCTAssertEqual(withAlert.item("m2")?.width, withAlert.item("m2")?.tab.restWidth)
        XCTAssertEqual(withAlert.item("m0")?.width, EarTabs.sliverWidth)
        let visible = layout(6, mode: .visible, alertAt: 2)
        XCTAssertEqual(visible.item("m2")?.width, visible.item("m2")?.tab.restWidth, "alerte : déployée, pas une tranche")
    }

    /// Un intercalaire sans information a déjà la largeur d'une tranche : rien à cacher.
    func testIconOnlyTabNeedsNoSlice() {
        let iconOnly = EarTabs.tabs(claude: .none, claudeEars: nil, modules: (0..<3).map {
            ModuleEarsEntry(id: "i\($0)", ears: ModuleEars(symbol: "circle", text: "", priority: 100 - $0))
        }, showEars: true)
        let fan = EarTabsLayout(tabs: iconOnly, notch: notch, mode: .visible)
        for item in fan.items {
            XCTAssertEqual(item.width, EarTabs.sliceWidth)
            XCTAssertTrue(item.showsInfo, "toute son information (aucune) est visible")
        }
    }

    // MARK: - Pile et zones de survol

    /// Du dessus vers le dessous : un point qui tombe sur deux corps est au premier de la pile (le plus près de la notch) ;
    /// un coin arrondi du premier laisse voir le corps du suivant, qui est donc touché là.
    func testTopOfTheStackWinsAndARoundedCornerRevealsTheOneBelow() {
        let fan = layout(4)
        let top = fan.left[0], below = fan.left[1]
        XCTAssertTrue(top.bodyFrame.intersects(below.bodyFrame), "les corps se chevauchent")
        let underTop = CGPoint(x: top.frame.midX, y: 5)
        XCTAssertTrue(below.bodyFrame.contains(underTop) || top.bodyFrame.contains(underTop))
        XCTAssertEqual(fan.hit(CGPoint(x: top.frame.minX + 3, y: 5), hovered: nil, cardHeight: 0), .tab(top.id))
        // Le coin bas extérieur arrondi du premier : vide s'il est seul, le corps du deuxième s'y voit.
        let corner = CGPoint(x: top.frame.minX + 0.4, y: top.height - 0.4)
        XCTAssertEqual(fan.hit(corner, hovered: nil, cardHeight: 0), .tab(below.id), "même hauteur : il comble le coin")
        XCTAssertEqual(layout(2).hit(CGPoint(x: layout(2).left[0].frame.minX + 0.4, y: top.height - 0.4),
                                     hovered: nil, cardHeight: 0), .none)
        // Sa tranche, elle, est à lui.
        XCTAssertEqual(fan.hit(CGPoint(x: below.frame.midX, y: 5), hovered: nil, cardHeight: 0), .tab(below.id))
    }

    /// Chaque point n'est que dans une zone, et un point de la tranche visible de chacun ouvre bien celui-là.
    func testEverySliceIsHitByItsOwnPoints() {
        let fan = layout(6)
        for item in fan.items {
            for y in stride(from: CGFloat(0.5), to: item.height - 6, by: 2) {
                let point = CGPoint(x: item.frame.midX, y: y)
                XCTAssertEqual(fan.hit(point, hovered: nil, cardHeight: 0), .tab(item.id), "\(item.id) (\(point.x), \(y))")
            }
        }
    }

    /// Le cœur de la leçon 1.2.1 : ouvrir un intercalaire ne change la cible d'aucun point, sauf pour la lui donner. Un point
    /// qui visait un intercalaire plus près de la notch le vise encore ; la notch aussi ; ce que l'intercalaire ouvert
    /// recouvre (ses voisins plus loin que lui) devient à lui, rien ne glisse sous la souris.
    func testOpeningATabOnlyGrowsItsOwnZone() {
        let fan = layout(6)
        for item in fan.items {
            for cardHeight: CGFloat in [0, 32, 60, 140] {
                var x: CGFloat = -330
                while x <= 330 {
                    for y in stride(from: CGFloat(0), through: 150, by: 1.5) {
                        let point = CGPoint(x: x, y: y)
                        let before = fan.hit(point, hovered: nil, cardHeight: cardHeight)
                        let after = fan.hit(point, hovered: item.id, cardHeight: cardHeight)
                        if before == .tab(item.id) {
                            XCTAssertEqual(after, .tab(item.id), "\(item.id) ne perd pas sa zone de repos (\(x), \(y), \(cardHeight))")
                        } else if after != before {
                            XCTAssertEqual(after, .tab(item.id), "(\(x), \(y)) change de cible sans être au déployé")
                            if case .tab(let id) = before, let covered = fan.item(id) {
                                XCTAssertEqual(covered.side, item.side)
                                XCTAssertGreaterThan(covered.rank, item.rank, "\(id) est plus près de la notch : jamais recouvert")
                            }
                        }
                    }
                    x += 1.5
                }
            }
        }
    }

    /// Ouvrir puis refermer remet exactement les zones de repos : rien n'a bougé entre-temps.
    func testFoldingGivesBackTheRestZones() {
        let fan = layout(6)
        let rest = fan.items.map { $0.frame }
        for item in fan.items { _ = fan.cardFrame(item, height: 100) }
        XCTAssertEqual(fan.items.map { $0.frame }, rest)
        XCTAssertEqual(fan.signature, layout(6).signature)
    }

    /// L'intercalaire ouvert grandit vers l'extérieur et vers le bas à partir de sa tranche, sans bouger son bord intérieur ;
    /// les voisins plus loin que lui sont dessous, ceux plus près de la notch restent entiers.
    func testOpenedCardStartsAtItsSliceAndLeavesCloserTabsWhole() {
        let fan = layout(6)
        for item in fan.items {
            let card = fan.cardFrame(item, height: 90)
            let edge = item.outward * item.inner
            XCTAssertEqual(item.side == .left ? card.maxX : card.minX, edge, accuracy: 0.001)
            for closer in fan.items where closer.side == item.side && closer.rank < item.rank {
                XCTAssertFalse(card.intersects(closer.frame.insetBy(dx: 0.01, dy: 0.01)),
                               "\(item.id) ouvert n'entre pas dans \(closer.id)")
            }
        }
    }

    /// Le coin intérieur d'une carte ouverte ne commence pas au-dessus du bas de la notch (et des intercalaires, qui ont sa
    /// hauteur) : jamais de jour contre eux.
    func testCardInnerRadiusStaysBelowTheBase() {
        let fan = layout(6)
        XCTAssertEqual(fan.cardInnerRadius(height: 0), 0, "carte basse : coin droit")
        XCTAssertEqual(fan.cardInnerRadius(height: notch.height), 0)
        XCTAssertEqual(fan.cardInnerRadius(height: notch.height + 5), 5, accuracy: 0.001)
        XCTAssertEqual(fan.cardInnerRadius(height: 1000), EarTabs.cardRadius)
    }

    /// Alignés sur la notch : même haut, même bas, base continue, à tout rang, rétractés ou non, ouverts ou non. Seule la
    /// superposition (horizontale) distingue les rangs.
    func testTabsStayAlignedWithTheNotch() {
        for mode in [EarTabsMode.visible, .retracted] {
            let fan = layout(6, mode: mode)
            for item in fan.items {
                XCTAssertEqual(item.frame.minY, 0)
                XCTAssertEqual(item.frame.maxY, notch.height, "\(item.id) : même bas que la notch")
                XCTAssertEqual(item.bodyFrame.minY, 0)
                XCTAssertEqual(item.bodyFrame.maxY, notch.height)
                XCTAssertEqual(fan.cardFrame(item, height: 0).minY, 0, "ouvert : même haut")
                XCTAssertEqual(fan.cardFrame(item, height: 0).maxY, notch.height, "carte basse : même bas")
                XCTAssertEqual(fan.cardFrame(item, height: 90).minY, 0)
            }
        }
    }

    func testRoundedInnerCornerOfAnOpenedCardIsOutsideItsZone() {
        let fan = layout(3)
        let item = fan.left[1]
        let height = notch.height + EarTabs.cardRadius + 10
        let card = fan.cardFrame(item, height: height)
        let corner = CGPoint(x: card.maxX - 0.4, y: card.maxY - 0.4)
        XCTAssertEqual(fan.hit(corner, hovered: item.id, cardHeight: height), .none, "le coin arrondi n'est pas la carte")
        XCTAssertEqual(fan.hit(CGPoint(x: card.maxX - 0.4, y: card.maxY - EarTabs.cardRadius - 1), hovered: item.id,
                               cardHeight: height), .tab(item.id))
    }
}
