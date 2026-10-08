import AppKit

/// A read-only search. Nothing is linked or uploaded until setup's Connect action.
@MainActor
final class FlomoMemoPicker: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let client: FlomoSearching
    private let alert = NSAlert()
    private let query = NSSearchField()
    private let searchButton = NSButton(title: L10n.tr("Search"), target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: L10n.tr("Enter a distinctive phrase from your memo."))
    private let table = NSTableView()
    private var task: Task<Void, Never>?
    private(set) var results: [FlomoMemoPreview] = []
    private var isClosed = false

    init(client: FlomoSearching) {
        self.client = client
        super.init()
        alert.messageText = L10n.tr("Find an existing Flomo memo")
        alert.informativeText = L10n.tr("Search by text, then select the memo you want to link. No URL or ID needed.")
        alert.addButton(withTitle: L10n.tr("Use Selected Memo")).isEnabled = false
        alert.addButton(withTitle: L10n.tr("Cancel"))

        query.placeholderString = L10n.tr("Words or a sentence from the memo")
        query.setAccessibilityLabel(L10n.tr("Search Flomo memos"))
        query.sendsSearchStringImmediately = false
        query.sendsWholeSearchString = true
        query.target = self
        query.action = #selector(search)
        searchButton.target = self
        searchButton.action = #selector(search)
        let row = NSStackView(views: [query, searchButton])
        row.orientation = .horizontal
        row.spacing = 8
        query.widthAnchor.constraint(equalToConstant: 430).isActive = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("memo"))
        column.width = 520
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 90
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel(L10n.tr("Matching Flomo memos"))
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = table
        scroll.widthAnchor.constraint(equalToConstant: 540).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 320).isActive = true
        status.font = .systemFont(ofSize: 11)
        status.widthAnchor.constraint(equalToConstant: 540).isActive = true
        let stack = NSStackView(views: [row, status, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.frame.size = NSSize(width: 540, height: 390)
        alert.accessoryView = stack
    }

    func run() -> FlomoMemoPreview? {
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        isClosed = true
        task?.cancel()
        guard response == .alertFirstButtonReturn, results.indices.contains(table.selectedRow) else { return nil }
        return results[table.selectedRow]
    }

    @objc private func search() {
        let keywords = query.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keywords.isEmpty, task == nil else { return }
        results = []
        table.reloadData()
        table.deselectAll(nil)
        alert.buttons[0].isEnabled = false
        searchButton.isEnabled = false
        query.isEnabled = false
        status.stringValue = L10n.tr("Searching Flomo…")
        task = Task { [weak self, client] in
            do {
                let matches = try await client.search(keywords: keywords)
                guard let self, !self.isClosed, !Task.isCancelled else { return }
                self.results = matches
                self.table.reloadData()
                self.status.stringValue = matches.isEmpty ? L10n.tr("No matches. Try another phrase.")
                    : L10n.format("%d matches. Select a preview below. Refine the search if needed (up to 50 results).", matches.count)
                self.finishSearch()
            } catch {
                guard let self, !self.isClosed, !Task.isCancelled else { return }
                self.status.stringValue = error.localizedDescription
                self.finishSearch()
            }
        }
    }

    private func finishSearch() {
        task = nil
        searchButton.isEnabled = true
        query.isEnabled = true
    }

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let memo = results[row]
        let date = memo.updatedAt.replacingOccurrences(of: "T", with: " ")
        let preview = SyncDocument.fromFlomo(memo.content).replacingOccurrences(of: "\n", with: "  ")
        let label = NSTextField(wrappingLabelWithString: "\(date)\(memo.truncated ? L10n.tr(" · excerpt") : "")\n\(preview)")
        label.font = .systemFont(ofSize: 12)
        label.maximumNumberOfLines = 4
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = memo.content
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        alert.buttons[0].isEnabled = results.indices.contains(table.selectedRow)
    }
}
