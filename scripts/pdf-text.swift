import Foundation
import PDFKit

// Prints a PDF's text (scripts/check-public.sh).
guard CommandLine.arguments.count == 2,
      let document = PDFDocument(url: URL(fileURLWithPath: CommandLine.arguments[1])) else {
    FileHandle.standardError.write(Data("pdf-text: cannot read the PDF\n".utf8))
    exit(1)
}
print(document.string ?? "")
