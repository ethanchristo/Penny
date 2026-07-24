//
//  GoogleScriptGenerator.swift
//  Penny
//
//  Created by Ethan Christo on 1/21/26.
//

import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct GoogleScriptDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText, .sourceCode] }
        
    var text: String
    
    // 1. We no longer need to pass [Card] in here since Apple Intelligence handles it!
    init() {
        self.text = GoogleScriptDocument.generateScriptContent()
    }
    
    init(configuration: ReadConfiguration) throws {
        if let data = configuration.file.regularFileContents {
            text = String(decoding: data, as: UTF8.self)
        } else {
            text = ""
        }
    }
    
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = text.data(using: .utf8)!
        return FileWrapper(regularFileWithContents: data)
    }
    
    // MARK: - Script Generation
    
    static private func generatePassword(length: Int = 20) -> String {
        let letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
        let numbers = "0123456789"
        let symbols = "!@#$%^&*()_+-=[]{}|;':,./<>?"
        let allowedChars = letters + numbers + symbols
        return String((0..<length).map { _ in allowedChars.randomElement()! })
    }

    static private func generateScriptContent() -> String {
        let mySecret = generatePassword()
        
        return #"""
        // ---------- MAIN ENTRY ----------
        function doGet(e) {
          // 1. SECURITY CHECK
          var mySecret = "\#(mySecret)";
        
          if (!e.parameter.secret || e.parameter.secret !== mySecret) {
            return ContentService.createTextOutput(JSON.stringify({error: "Unauthorized"}))
              .setMimeType(ContentService.MimeType.JSON);
          }
        
          // 2. SEARCH GMAIL
          var threads = GmailApp.search('label:Transactions', 0, 20);
          var rawEmails = [];
        
          for (var i = 0; i < threads.length; i++) {
            var messages = threads[i].getMessages();
            
            for (var j = 0; j < messages.length; j++) {
              var msg = messages[j];
        
              if (!msg.isUnread()) {
                continue; 
              }
        
              var body = msg.getPlainBody() || msg.getBody() || "";
        
              // 3. PUSH RAW TEXT (Letting Swift AI do the hard work!)
              rawEmails.push({
                body: body,
                date: Utilities.formatDate(msg.getDate(), Session.getScriptTimeZone(), "yyyy-MM-dd'T'HH:mm:ss'Z'")
              });
            }
          }
        
          deleteTransactionsLabelEmails();
        
          // 4. RETURN JSON
          return ContentService.createTextOutput(JSON.stringify(rawEmails))
            .setMimeType(ContentService.MimeType.JSON);
        }
        
        // ---------- HELPERS ----------
        
        function deleteTransactionsLabelEmails() {
          const LABEL_NAME = "Transactions";
          const transactionsLabel = GmailApp.getUserLabelByName(LABEL_NAME);
          if (!transactionsLabel) throw new Error(`Label "${LABEL_NAME}" does not exist.`);
        
          const threads = transactionsLabel.getThreads();
          let deletedCount = 0;
        
          threads.forEach(thread => {
            thread.markRead();
            GmailApp.moveThreadToTrash(thread);
            thread.removeLabel(transactionsLabel);
            deletedCount++;
          });
        
          return deletedCount;
        }
        """#
    }
}
