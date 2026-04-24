import Foundation

enum ModelDownloadEvent: Equatable {
    case located(URL)
    case starting(expectedBytes: Int64?)
    case downloading(bytesWritten: Int64, totalBytes: Int64?)
    case finished(URL)
}
