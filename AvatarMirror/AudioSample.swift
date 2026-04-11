import Foundation

/// Built-in audio samples for testing lip sync.
struct AudioSample: Identifiable {
    let id: String
    let name: String
    let voice: String
    let language: String
    let filename: String
    
    var url: URL? {
        // Resources is a folder reference in the bundle
        Bundle.main.url(forResource: filename, withExtension: "mp3")
    }
    
    static let all: [AudioSample] = [
        AudioSample(id: "01", name: "早上好", voice: "Amy", language: "中文", filename: "01_amy_greeting"),
        AudioSample(id: "02", name: "温柔", voice: "Sage", language: "中文", filename: "02_sage_gentle"),
        AudioSample(id: "03", name: "看电影", voice: "Anna Su", language: "中文", filename: "03_anna_chat"),
        AudioSample(id: "04", name: "搞笑", voice: "Amy", language: "中文", filename: "04_amy_funny"),
        AudioSample(id: "05", name: "小猫咪", voice: "Sage", language: "中文", filename: "05_sage_story"),
        AudioSample(id: "06", name: "Story", voice: "George", language: "EN", filename: "06_george_story"),
        AudioSample(id: "07", name: "Amazing", voice: "Sarah", language: "EN", filename: "07_sarah_praise"),
        AudioSample(id: "08", name: "Meeting", voice: "Brian", language: "EN", filename: "08_brian_work"),
    ]
}
