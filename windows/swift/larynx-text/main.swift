import Foundation
import LarynxTextJSON

// larynx-text: the text cleanup as a small long-running process. One JSON request per line on stdin, one JSON
// reply per line on stdout (see LarynxTextJSON/Clean.swift). The Windows app starts it once and keeps it.
// Every reply is flushed by hand (setvbuf with size 0 aborts in the MSVC runtime).
warmUp()
print("{\"ready\":true}")
fflush(stdout)
while let line = readLine(strippingNewline: true) {
    if line.isEmpty { continue }
    print(cleanJSON(line))
    fflush(stdout)
}
