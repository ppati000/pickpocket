//
//  ContentView.swift
//  Pickpocket
//
//  Created by Patrick Petrovic on 31.12.23.
//

import SwiftUI
import SwiftSoup
import SafariServices

typealias URLTitlePair = (url: String, title: String?)

struct ContentView: View {
    @Environment(\.scenePhase) var scenePhase
    
    @State private var readLinks = [URLTitlePair]()
    @State private var unreadLinks = [URLTitlePair]()
    @State private var links = [URLTitlePair]()

    @State private var shouldIncludeReadItems = false
    @State private var showingDocumentPicker = false
    
    @State private var isAddingLinks = false
    @State private var addedCount = 0
    @State private var failedCount = 0
    
    @State private var showingAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    
    init(unreadLinks: [URLTitlePair] = []) {
        self._unreadLinks = State(initialValue: unreadLinks)
        self._links = State(initialValue: unreadLinks)
    }

    var body: some View {
        VStack {
            if links.isEmpty {
                Text("Pickpocket").font(.largeTitle).bold()
                    .padding()
                Image("pickpocket-modified")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                Text("Pickpocket import your saved links from Pocket to your Safari reading list. Just follow the instructions below!")
                    .padding()
                Text("1. Download your Pocket export file").font(.headline)
                    .padding(.vertical, -5)
                Link("Download Export File", destination: URL(string: "https://getpocket.com/export")!)
                    .padding()
                
                Text("2. Load the downloaded file").font(.headline)
                    .padding(.vertical, -5)
                Button("Load Pocket Export File") {
                    showingDocumentPicker = true
                }
                
                .buttonStyle(.borderedProminent)
                .padding()
                .padding(.bottom, 20)
                .sheet(isPresented: $showingDocumentPicker) {
                    DocumentPicker { url in
                        loadAndParseHTML(fileURL: url)
                    }
                }
            } else {
                let effectiveLinks = shouldIncludeReadItems ? links : unreadLinks
                Text("Pickpocket").font(.title).bold()
                List(effectiveLinks, id: \.self.url) { link in
                    VStack(alignment: .leading) {
                        Text(link.title ?? "Untitled Link")
                            .font(.headline)
                        Text(link.url)
                            .font(.subheadline)
                            .foregroundColor(.gray)
                    }
                }
                    .listStyle(.plain)
                if isAddingLinks {
                    VStack {
                        ProgressView("Adding to Reading List", value: Float(addedCount + failedCount), total: Float(links.count))
                        Text("Added: \(addedCount) / Failed: \(failedCount)")
                    }
                    .padding()
                } else if links.count > 0 {
                    Toggle("Include Read Items", isOn: $shouldIncludeReadItems)
                        .padding()
                        .padding(.bottom, -10)
                        .frame(minWidth: 0, maxWidth: 250)
                    Button("Add \(effectiveLinks.count) Links to Reading List") {
                        isAddingLinks = true
                        if (ProcessInfo.processInfo.isiOSAppOnMac) {
                            print("Running on macOS. Adding all links at once.")
                            processAllLinks()
                        } else {
                            print("Running on iOS; need user interaction. Adding links one by one.")
                            processNextLink()
                        }
                    }
                        .padding()
                        .padding(.top, -10)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 240/255, green: 245/255, blue: 250/255))
        .onChange(of: scenePhase) { oldPhase, newPhase in
            if oldPhase == .inactive && newPhase == .active && !ProcessInfo.processInfo.isiOSAppOnMac && isAddingLinks {
                processNextLink()
            }
        }.alert(isPresented: $showingAlert) {
            Alert(
                title: Text(alertTitle),
                message: Text(alertMessage),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    func loadAndParseHTML(fileURL: URL) {
        guard fileURL.startAccessingSecurityScopedResource() else {
               alertTitle = "Error"
               alertMessage = "Could not access the file."
               showingAlert = true
               return
        }

        defer {
            fileURL.stopAccessingSecurityScopedResource()
        }

        do {
            let htmlString = try String(contentsOf: fileURL, encoding: .utf8)
            let doc = try SwiftSoup.parse(htmlString)

            unreadLinks = extractLinks(doc, inSection: "Unread")
            readLinks = extractLinks(doc, inSection: "Read Archive")
            links = unreadLinks + readLinks
        } catch {
            showAlert(title: "Error", message: "Could parse the file. Please select a different file.")
            return
        }

        if links.isEmpty {
            showAlert(title: "Error", message: "The selected file does not contain any links. Please select a different file.")
        }
    }

    func extractLinks(_ doc: Document, inSection section: String) -> [URLTitlePair] {
        do {
            let unreadHeader = try doc.select("h1:contains(\(section))").first()
            let ulElement = try unreadHeader?.nextElementSibling()
            return try ulElement?
                .select("a[href]")
                .array()
                .map { element in
                    let url = try! element.attr("href")
                    var title = try? element.text()
                    if title == url {
                        title = nil
                    }
                    return (url, title)
                } ?? []
        } catch {
            return []
        }
    }

    func processNextLink() {
        let effectiveLinks = shouldIncludeReadItems ? links : unreadLinks
        let index = effectiveLinks.count - (addedCount + failedCount) - 1
        if index < 0 {
            finishImport()
            return
        }
 
        if let list = SSReadingList.default() {
            if addToReadingList(list, effectiveLinks[index]) {
                addedCount += 1
            } else {
                failedCount += 1
            }
        }
    }

    func processAllLinks() {
        let effectiveLinks = shouldIncludeReadItems ? links : unreadLinks
        if let list = SSReadingList.default() {
            for link in effectiveLinks.reversed() {
                if addToReadingList(list, link) {
                    addedCount += 1
                } else {
                    failedCount += 1
                }
            }
        }
        finishImport()
    }

    func showAlert(title: String, message: String) {
        alertTitle = title
        alertMessage = message
        showingAlert = true
    }
    
    func finishImport() {
        showAlert(title: "Import Complete", message: "\(addedCount) links were successfully added to your Safari reading list.")
        isAddingLinks = false
    }

    func addToReadingList(_ list: SSReadingList, _ element: URLTitlePair) -> Bool {
        guard let url = URL(string: element.url) else { return false }
        do {
            try list.addItem(with: url, title: element.title, previewText: nil)
            return true
        } catch {
            print("Error adding to Reading List: \(error)")
            return false
        }
    }
}

#Preview {
    //ContentView()
    ContentView(unreadLinks: [("https://example.com", "Link Title")])
}
