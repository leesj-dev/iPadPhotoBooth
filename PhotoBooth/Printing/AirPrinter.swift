import UIKit
import BoothCore

@MainActor final class AirPrinter: NSObject, UIPrintInteractionControllerDelegate {
    private var completion: ((PrintState, String?) -> Void)?
    private var retainedData: Data?
    private var imageSize = CGSize(width: 3, height: 2)

    func present(data: Data, from view: UIView, jobName: String, completion: @escaping (PrintState, String?) -> Void) {
        guard self.completion == nil else { return }
        guard UIPrintInteractionController.isPrintingAvailable,
              UIPrintInteractionController.canPrint(data) else {
            completion(.failed, "AirPrint를 사용할 수 없습니다. 프린터의 네트워크 연결과 용지를 확인하세요.")
            return
        }
        self.completion = completion; retainedData = data
        imageSize = UIImage(data: data)?.size ?? CGSize(width: 3, height: 2)
        let controller = UIPrintInteractionController.shared
        controller.delegate = self
        let info = UIPrintInfo(dictionary: nil)
        info.jobName = jobName
        info.outputType = .photo
        info.orientation = Self.orientation(for: data)
        info.duplex = .none
        controller.printInfo = info
        controller.printingItem = data
        controller.showsNumberOfCopies = true
        controller.showsPaperSelectionForLoadedPapers = true
        let presented = controller.present(from: view.bounds, in: view, animated: true) { [weak self] _, completed, error in
            guard let self else { return }
            let callback = self.completion
            self.completion = nil; self.retainedData = nil
            if let error { callback?(.failed, error.localizedDescription) }
            else { callback?(completed ? .submitted : .cancelled, nil) }
        }
        if !presented {
            self.completion = nil; retainedData = nil
            completion(.failed, "인쇄 창을 열지 못했습니다. 다시 시도하세요.")
        }
    }

    static func orientation(for data: Data) -> UIPrintInfo.Orientation {
        guard let image = UIImage(data: data) else { return .portrait }
        return image.size.width > image.size.height ? .landscape : .portrait
    }

    static func pageSize(for orientation: UIPrintInfo.Orientation) -> CGSize {
        orientation == .landscape ? CGSize(width: 432, height: 288) : CGSize(width: 288, height: 432)
    }

    /// Rank only printer-advertised sizes; orientation does not affect the aspect match.
    /// With equal aspect ratios, prefer the size closest to a standard 6×4 photo.
    static func preferredPaperIndex(paperSizes: [CGSize], imageSize: CGSize) -> Int? {
        guard imageSize.width.isFinite, imageSize.height.isFinite,
              imageSize.width > 0, imageSize.height > 0 else { return nil }
        let imageRatio = max(imageSize.width, imageSize.height) / min(imageSize.width, imageSize.height)
        var best: (index: Int, aspectError: CGFloat, sizeError: CGFloat)?
        for (index, size) in paperSizes.enumerated() {
            guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { continue }
            let ratio = max(size.width, size.height) / min(size.width, size.height)
            let aspectError = abs(log(ratio / imageRatio))
            let sizeError = abs(log((size.width * size.height) / (432 * 288)))
            if let current = best,
               !(aspectError < current.aspectError - 0.000001
                 || (abs(aspectError - current.aspectError) <= 0.000001 && sizeError < current.sizeError)) {
                continue
            }
            best = (index, aspectError, sizeError)
        }
        return best?.index
    }

    func printInteractionController(_ printInteractionController: UIPrintInteractionController,
                                    choosePaper paperList: [UIPrintPaper]) -> UIPrintPaper {
        if let index = Self.preferredPaperIndex(paperSizes: paperList.map(\.paperSize), imageSize: imageSize) {
            return paperList[index]
        }
        return UIPrintPaper.bestPaper(forPageSize: Self.pageSize(for: printInteractionController.printInfo?.orientation ?? .portrait), withPapersFrom: paperList)
    }
}
