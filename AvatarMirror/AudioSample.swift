import Foundation

/// Built-in audio samples for testing lip sync.
struct AudioSample: Identifiable {
    let id: String
    let name: String
    let voice: String
    let language: String
    let filename: String
    
    var url: URL? {
        Bundle.main.url(forResource: filename, withExtension: "caf", subdirectory: "Resources/AudioSamples")
    }
    
    static let all: [AudioSample] = [
        AudioSample(id: "01", name: "早上好", voice: "婷婷", language: "中文", filename: "01_tingting_greeting"),
        AudioSample(id: "02", name: "看电影", voice: "Shelley", language: "中文", filename: "02_shelley_chat"),
        AudioSample(id: "03", name: "开会", voice: "Reed", language: "中文", filename: "03_reed_work"),
        AudioSample(id: "04", name: "搞笑", voice: "Rocko", language: "中文", filename: "04_rocko_funny"),
        AudioSample(id: "05", name: "温柔", voice: "Sandy", language: "中文", filename: "05_sandy_gentle"),
        AudioSample(id: "06", name: "Coffee", voice: "Daniel", language: "EN", filename: "06_daniel_english"),
        AudioSample(id: "07", name: "Amazing", voice: "Flo", language: "EN", filename: "07_flo_english"),
        AudioSample(id: "08", name: "小猫咪", voice: "爷爷", language: "中文", filename: "08_grandpa_story"),
    ]
}
