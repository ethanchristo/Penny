//
//  Structs.swift
//  Penny
//
//  Created by Ethan Christo on 7/20/26.
//

import SwiftUI

struct SquigglyLine: Shape {
    var wavelength: CGFloat = 10
    var amplitude: CGFloat = 4

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let midY = rect.midY
        
        path.move(to: CGPoint(x: rect.minX, y: midY))
        
        // Loop across the width to draw points along the sine wave
        for x in stride(from: rect.minX, to: rect.maxX, by: 1) {
            let relativeX = x / wavelength
            let y = midY + sin(relativeX * 2 * .pi) * amplitude
            path.addLine(to: CGPoint(x: x, y: y))
        }
        
        return path
    }
}
