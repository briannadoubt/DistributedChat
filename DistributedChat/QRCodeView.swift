//
//  QRCodeView.swift
//  DistributedChat
//
//  Created by Bri on 7/21/22.
//

import SwiftUI
import CoreImage.CIFilterBuiltins

struct QRCodeView: View {
    
    let chatId: UUID
    @Environment(\.presentationMode) var presentationMode
    
#if os(macOS)
    @State var qrImage: NSImage?
#else
    @State var qrImage: UIImage?
#endif
    
    let context = CIContext()
    let filter = CIFilter.qrCodeGenerator()
    
#if os(macOS)
    func generateQRCode(from string: String) -> NSImage? {
        let data = string.data(using: String.Encoding.ascii)

        if let filter = CIFilter(name: "CIQRCodeGenerator") {
            filter.setValue(data, forKey: "inputMessage")
            let transform = CGAffineTransform(scaleX: 3, y: 3)
            if let output = filter.outputImage?.transformed(by: transform) {
                let nsciImage = NSCIImageRep(ciImage: output)
                let image = NSImage(size: nsciImage.size)
                image.addRepresentation(nsciImage)
                return image
            }
        }

        return nil
    }
#else
    func generateQRCode(from string: String) -> UIImage {
        filter.message = Data(string.utf8)

        if let outputImage = filter.outputImage {
            if let cgimg = context.createCGImage(outputImage, from: outputImage.extent) {
                return UIImage(cgImage: cgimg)
            }
        }
        return UIImage(systemName: "xmark.circle") ?? UIImage()
    }
#endif
    
    var body: some View {
        VStack {
            if let qrCodeImage = qrImage {
                #if os(macOS)
                Image(nsImage: qrCodeImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 160, height: 160)
                #else
                Image(uiImage: qrCodeImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                #endif
            } else {
                Text("Failed to generate QR Code Image")
            }
        }
        .task {
            if qrImage == nil {
                qrImage = generateQRCode(from: "distributedChat://chat?chatId=\(chatId.uuidString)")
            }
        }
    }
}
