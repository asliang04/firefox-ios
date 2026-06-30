// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
import Foundation
import Shared
import ComponentLibrary

class ContentBlockerSettingViewController: SettingsTableViewController {
    private struct UX {
        static let buttonContentInsets = NSDirectionalEdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0)
    }

    private lazy var linkButton: LinkButton = .build()
    private let filterListManager = FilterListManager.shared
    let prefs: Prefs
    var currentBlockingStrength: BlockingStrength

    init(windowUUID: WindowUUID,
         prefs: Prefs,
         isShownFromSettings: Bool = true) {
        self.prefs = prefs

        currentBlockingStrength = prefs.stringForKey(ContentBlockingConfig.Prefs.StrengthKey).flatMap({
            BlockingStrength(rawValue: $0)
        }) ?? .basic

        super.init(style: .grouped, windowUUID: windowUUID)

        self.title = .SettingsTrackingProtectionSectionName

        if !isShownFromSettings {
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                title: .AppSettingsDone,
                style: .plain,
                target: self,
                action: #selector(done))
            if #available(iOS 26.0, *) {
                let theme = themeManager.getCurrentTheme(for: windowUUID)
                navigationItem.rightBarButtonItem?.tintColor = theme.colors.textPrimary
            }
        }
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        applyTheme()
        startObservingNotifications(
            withNotificationCenter: notificationCenter,
            forObserver: self,
            observing: [UIContentSizeCategory.didChangeNotification]
        )
    }

    override func didRotate(from fromInterfaceOrientation: UIInterfaceOrientation) {
        tableView.reloadData()
    }

    override func generateSettings() -> [SettingSection] {
        let strengthSetting: [CheckmarkSetting] = BlockingStrength.allOptions.map { option in
            let id = BlockingStrength.accessibilityId(for: option)
            let setting = CheckmarkSetting(
                title: NSAttributedString(string: option.settingTitle),
                style: .leftSide,
                subtitle: NSAttributedString(string: option.settingSubtitle),
                accessibilityIdentifier: id,
                isChecked: {
                    return option == self.currentBlockingStrength
                },
                onChecked: {
                    let previousOption = self.currentBlockingStrength

                    self.currentBlockingStrength = option
                    self.prefs.setString(self.currentBlockingStrength.rawValue,
                                         forKey: ContentBlockingConfig.Prefs.StrengthKey)
                    TabContentBlocker.prefsChanged()
                    self.tableView.reloadData()

                    self.recordEventOnChecked(option: option, fromOption: previousOption)
                })

            let uuid = windowUUID
            setting.onAccessoryButtonTapped = {
                let vc = TPAccessoryInfo(windowUUID: uuid)
                vc.isStrictMode = option == .strict
                self.navigationController?.pushViewController(vc, animated: true)
            }

            if self.prefs.boolForKey(ContentBlockingConfig.Prefs.EnabledKey) == false {
                setting.enabled = false
            }
            return setting
        }

        var sections: [SettingSection] = []

        if let profile {
            let enabledSetting = BoolSetting(
                prefs: profile.prefs,
                prefKey: ContentBlockingConfig.Prefs.EnabledKey,
                defaultValue: ContentBlockingConfig.Defaults.NormalBrowsing,
                attributedTitleText: NSAttributedString(string: .TrackingProtectionEnableTitle)) { [weak self] enabled in
                    TabContentBlocker.prefsChanged()
                    strengthSetting.forEach { item in
                        item.enabled = enabled
                    }
                    self?.tableView.reloadData()
                    TelemetryWrapper.recordEvent(category: .action,
                                                 method: .tap,
                                                 object: .trackingProtectionMenu,
                                                 extras: [TelemetryWrapper.EventExtraKey.etpEnabled.rawValue: enabled] )
            }

            let firstSection = SettingSection(
                title: nil,
                footerTitle: NSAttributedString(string: .TrackingProtectionCellFooter),
                children: [enabledSetting]
            )
            sections.append(firstSection)
        }

        let optionalFooterTitle = NSAttributedString(string: .TrackingProtectionLevelFooter)

        // The bottom of the block lists section has a More Info button, implemented as a custom footer view,
        // SettingSection needs footerTitle set to create a footer, which we then override the view for.
        let blockListsTitle: String = .TrackingProtectionOptionProtectionLevelTitle
        let secondSection = SettingSection(
            title: NSAttributedString(string: blockListsTitle),
            footerTitle: optionalFooterTitle,
            children: strengthSetting
        )
        sections.append(secondSection)

        let filterListSettings = filterListManager.records().map { record in
            FilterListSetting(record: record) { [weak self] isEnabled in
                self?.filterListManager.setEnabled(isEnabled, for: record.id)
                self?.compilePersonalFilterLists()
            }
        }

        let customListsFooter = NSAttributedString(
            string: "Enabled downloaded lists are converted into WebKit content blockers. "
                + "This first pass supports common network-blocking rules, but not cosmetic filtering "
                + "or every uBlock rule type."
        )
        sections.append(
            SettingSection(
                title: NSAttributedString(string: "Custom filter lists"),
                footerTitle: customListsFooter,
                children: [
                    AddFilterListSetting { [weak self] urlString in
                        self?.addCustomFilterList(urlString: urlString)
                    },
                    RefreshFilterListsSetting { [weak self] in
                        self?.refreshEnabledFilterLists()
                    }
                ] + filterListSettings
            )
        )

        return sections
    }

    private func addCustomFilterList(urlString: String) {
        Task { [weak self] in
            guard let self else { return }
            let result = await filterListManager.addCustomList(from: urlString)
            if case .failure(let error) = result {
                settings = generateSettings()
                tableView.reloadData()
                presentFilterListError(error.localizedDescription)
            } else {
                compilePersonalFilterLists()
            }
        }
    }

    private func refreshEnabledFilterLists() {
        Task { [weak self] in
            guard let self else { return }
            _ = await filterListManager.refreshEnabledLists()
            compilePersonalFilterLists()
        }
    }

    private func compilePersonalFilterLists() {
        ContentBlocker.shared.compilePersonalFilterLists { [weak self] in
            guard let self else { return }
            TabContentBlocker.prefsChanged()
            settings = generateSettings()
            tableView.reloadData()
        }
    }

    private func presentFilterListError(_ message: String) {
        let alert = UIAlertController(title: "Filter list error", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: .OKString, style: .default))
        present(alert, animated: true)
    }

    private func recordEventOnChecked(option: BlockingStrength, fromOption: BlockingStrength) {
        SettingsTelemetry().changedSetting("ETP-strength", to: option.rawValue, from: fromOption.rawValue)

        if option == .strict {
            TelemetryWrapper.recordEvent(
                category: .action,
                method: .tap,
                object: .trackingProtectionMenu,
                extras: [TelemetryWrapper.EventExtraKey.etpSetting.rawValue: option.rawValue]
            )
        } else {
            TelemetryWrapper.recordEvent(
                category: .action,
                method: .tap,
                object: .trackingProtectionMenu,
                extras: [TelemetryWrapper.EventExtraKey.etpSetting.rawValue: "standard"]
            )
        }
    }

    // The first section header gets a More Info link
    override func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
        let _defaultFooter = super.tableView(
            tableView,
            viewForFooterInSection: section
        ) as? ThemedTableSectionHeaderFooterView
        guard let defaultFooter = _defaultFooter else { return nil }

        if section == 0 {
            let linkButtonViewModel = LinkButtonViewModel(
                title: .TrackerProtectionLearnMore,
                a11yIdentifier: AccessibilityIdentifiers.Settings.ContentBlocker.title,
                font: FXFontStyles.Regular.caption1.scaledFont(),
                contentInsets: UX.buttonContentInsets
            )
            linkButton.configure(viewModel: linkButtonViewModel)

            linkButton.addTarget(self, action: #selector(moreInfoTapped), for: .touchUpInside)

            defaultFooter.stackView.addArrangedSubview(linkButton)

            return defaultFooter
        }

        if section == 1 && currentBlockingStrength == .basic {
            return nil
        }

        return defaultFooter
    }

    override func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        return UITableView.automaticDimension
    }

    @objc
    func moreInfoTapped() {
        let viewController = SettingsContentViewController(windowUUID: windowUUID)
        viewController.url = SupportUtils.URLForTopic("tracking-protection-ios")
        navigationController?.pushViewController(viewController, animated: true)
    }

    @objc
    func done() {
        settingsDelegate?.didFinish()
    }

    // MARK: - ThemeApplicable
    override func applyTheme() {
        super.applyTheme()
        let currentTheme = currentTheme()
        linkButton.applyTheme(theme: currentTheme)
    }

    // MARK: - Notifiable
    override func handleNotifications(_ notification: Notification) {
        super.handleNotifications(notification)

        switch notification.name {
        case UIContentSizeCategory.didChangeNotification:
            ensureMainThread {
                self.tableView.reloadData()
            }
        default:
            break
        }
    }
}

private final class AddFilterListSetting: Setting {
    private let onAdd: (String) -> Void

    override var accessoryView: UIImageView? {
        guard let theme else { return nil }
        return SettingDisclosureUtility.buildDisclosureIndicator(theme: theme)
    }

    init(onAdd: @escaping (String) -> Void) {
        self.onAdd = onAdd
        super.init(title: NSAttributedString(string: "Add custom filter list"))
    }

    override func onClick(_ navigationController: UINavigationController?) {
        let alert = UIAlertController(
            title: "Add custom filter list",
            message: "Paste an ABP/uBlock-style filter-list URL. Supported network rules will be "
                + "converted into WebKit content blockers.",
            preferredStyle: .alert
        )
        alert.addTextField { textField in
            textField.placeholder = "https://example.com/filter-list.txt"
            textField.keyboardType = .URL
            textField.autocapitalizationType = .none
            textField.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: .CancelString, style: .cancel))
        alert.addAction(UIAlertAction(title: "Download", style: .default) { [weak alert, onAdd] _ in
            let urlString = alert?.textFields?.first?.text ?? ""
            onAdd(urlString)
        })
        navigationController?.present(alert, animated: true)
    }
}

private final class RefreshFilterListsSetting: Setting {
    private let onRefresh: () -> Void

    init(onRefresh: @escaping () -> Void) {
        self.onRefresh = onRefresh
        super.init(title: NSAttributedString(string: "Refresh enabled filter lists"))
    }

    override func onClick(_ navigationController: UINavigationController?) {
        onRefresh()
    }
}

private final class FilterListSetting: BoolSetting {
    private let record: FilterListRecord

    init(record: FilterListRecord, settingDidChange: @escaping (Bool) -> Void) {
        self.record = record
        super.init(
            title: record.name,
            description: Self.statusText(for: record),
            prefs: nil,
            defaultValue: record.isEnabled,
            settingDidChange: settingDidChange
        )
    }

    override func displayBool(_ control: UISwitch) {
        control.isOn = record.isEnabled
    }

    override func writeBool(_ control: UISwitch) {}

    override func switchValueChanged(_ control: UISwitch) {
        settingDidChange?(control.isOn)
    }

    private static func statusText(for record: FilterListRecord) -> String {
        switch record.downloadState {
        case .neverDownloaded:
            return "Never downloaded - \(record.sourceURL.absoluteString)"
        case .downloading:
            return "Downloading - \(record.sourceURL.absoluteString)"
        case .downloaded:
            let size = record.byteCount.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
                ?? "unknown size"
            return "Downloaded \(size). \(compileStatusText(for: record)) - \(record.sourceURL.absoluteString)"
        case .failed:
            return "Failed: \(record.lastFailure ?? "Unknown error")"
        }
    }

    private static func compileStatusText(for record: FilterListRecord) -> String {
        switch record.compileState ?? .neverCompiled {
        case .neverCompiled:
            return "Not compiled"
        case .compiling:
            return "Compiling"
        case .compiled:
            let count = record.compiledRuleCount.map { "\($0) rules" } ?? "rules ready"
            return "Compiled \(count)"
        case .failed:
            return "Compile failed: \(record.compileFailure ?? "Unknown error")"
        }
    }
}
