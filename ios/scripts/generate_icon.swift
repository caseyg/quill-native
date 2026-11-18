import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let directory = URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
let context = CGContext(data:nil,width:1024,height:1024,bitsPerComponent:8,bytesPerRow:4096,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue)!
context.setFillColor(CGColor(red:0.32,green:0.20,blue:0.34,alpha:1)); context.fill(CGRect(x:0,y:0,width:1024,height:1024))
let feather = CGMutablePath()
feather.move(to:CGPoint(x:278,y:300))
feather.addCurve(to:CGPoint(x:742,y:800),control1:CGPoint(x:315,y:630),control2:CGPoint(x:493,y:846))
feather.addCurve(to:CGPoint(x:612,y:457),control1:CGPoint(x:804,y:684),control2:CGPoint(x:745,y:536))
feather.addLine(to:CGPoint(x:278,y:300)); feather.closeSubpath()
context.setFillColor(CGColor(gray:1,alpha:1)); context.addPath(feather); context.fillPath()
context.setStrokeColor(CGColor(red:0.32,green:0.20,blue:0.34,alpha:1)); context.setLineWidth(17); context.setLineCap(.round)
context.move(to:CGPoint(x:290,y:312)); context.addLine(to:CGPoint(x:678,y:728)); context.strokePath()
for (x,y) in [(440.0,474.0),(512.0,551.0),(579.0,623.0)] {
    context.move(to:CGPoint(x:x,y:y)); context.addLine(to:CGPoint(x:x+112,y:y+3)); context.strokePath()
}
context.setStrokeColor(CGColor(red:0.86,green:0.70,blue:0.58,alpha:1)); context.setLineWidth(12)
context.move(to:CGPoint(x:270,y:242)); context.addLine(to:CGPoint(x:754,y:242)); context.strokePath()
let destination = CGImageDestinationCreateWithURL(directory.appendingPathComponent("AppIcon.png") as CFURL,UTType.png.identifier as CFString,1,nil)!
CGImageDestinationAddImage(destination,context.makeImage()!,nil)
precondition(CGImageDestinationFinalize(destination))
