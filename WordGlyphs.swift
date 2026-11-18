import SwiftUI

enum Glyph {
    case symbol(String)   // SF Symbol name
    case emoji(String)
}

/// Words that get a small picture in the "Visual" styles.
/// Add your own by appending to the `add(...)` calls below.
enum WordGlyphs {
    static func glyph(for raw: String) -> Glyph? {
        // Only clean SF Symbols: the emoji entries made the lyrics look cheap, so they are skipped.
        guard let g = table[normalize(raw)] else { return nil }
        if case .emoji = g { return nil }
        return g
    }

    /// Colour of each picture.
    static func tint(for symbol: String) -> Color {
        switch symbol {
        case "heart.fill", "flame.fill", "gift.fill", "flag.fill", "bell.fill": return Color(red: 1.0, green: 0.32, blue: 0.38)
        case "sun.max.fill", "star.fill", "sparkles", "crown.fill", "key.fill", "bolt.fill", "lightbulb.fill": return Color(red: 1.0, green: 0.8, blue: 0.2)
        case "moon.fill", "moon.stars.fill", "moon.zzz.fill", "bed.double.fill": return Color(red: 0.62, green: 0.6, blue: 1.0)
        case "cloud.fill", "snowflake", "wind", "umbrella.fill", "cloud.rain.fill", "drop.fill", "water.waves": return Color(red: 0.45, green: 0.78, blue: 1.0)
        case "leaf.fill", "tree.fill", "camera.macro", "mountain.2.fill": return Color(red: 0.4, green: 0.88, blue: 0.5)
        case "globe", "airplane", "car.fill", "house.fill", "phone.fill", "message.fill", "bird.fill": return Color(red: 0.35, green: 0.7, blue: 1.0)
        case "music.note", "guitars.fill", "mic.fill", "headphones", "figure.dance": return Color(red: 0.9, green: 0.45, blue: 1.0)
        case "eye.fill", "hand.raised.fill", "figure.run", "figure.walk", "pawprint.fill": return Color(red: 1.0, green: 0.6, blue: 0.3)
        case "clock.fill", "lock.fill", "camera.fill", "cup.and.saucer.fill", "wineglass.fill", "dollarsign.circle.fill", "diamond.fill":
            return Color(red: 0.95, green: 0.85, blue: 0.7)
        default: return .white
        }
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
            .trimmingCharacters(in: CharacterSet.letters.inverted)
    }

    private static let table: [String: Glyph] = {
        var t: [String: Glyph] = [:]
        func add(_ words: [String], _ g: Glyph) { for w in words { t[w] = g } }

        // Love & feelings
        add(["love", "loved", "loving", "loves", "lover", "lovers", "heart", "hearts", "heartbeat"], .symbol("heart.fill"))
        add(["broken", "break", "breaking", "breaks", "heartbreak"], .emoji("💔"))
        add(["kiss", "kisses", "kissed", "kissing"], .emoji("💋"))
        add(["smile", "smiles", "smiling", "happy", "happiness", "joy"], .emoji("😊"))
        add(["cry", "cried", "crying", "tears", "tear"], .emoji("😢"))
        add(["laugh", "laughing", "laughter"], .emoji("😂"))
        add(["sad", "sorrow", "sorry", "blue"], .emoji("😔"))
        add(["angry", "anger", "mad", "rage"], .emoji("😠"))
        add(["fear", "scared", "afraid", "terror"], .emoji("😨"))
        add(["alone", "lonely", "lonesome"], .emoji("🥀"))
        add(["hurt", "hurts", "pain", "wound", "wounds"], .emoji("🩹"))
        add(["crown", "king", "queen", "royal"], .emoji("👑"))
        add(["camera", "picture", "pictures", "photograph"], .emoji("📷"))
        add(["mirror"], .emoji("🪞"))
        add(["book", "books", "page", "pages", "story"], .emoji("📖"))
        add(["write", "wrote", "writing", "pen"], .emoji("✍️"))

        // People & beliefs
        add(["angel", "angels", "heaven"], .emoji("😇"))
        add(["devil", "hell", "demon", "demons"], .emoji("😈"))
        add(["god", "pray", "prayer", "praying", "church", "lord", "holy"], .emoji("🙏"))
        add(["ghost", "ghosts", "haunted"], .emoji("👻"))
        add(["death", "dead", "die", "dying", "died", "kill", "killed"], .emoji("💀"))
        add(["grave", "graves"], .emoji("⚰️"))
        add(["war", "fight", "fighting", "battle", "sword"], .emoji("⚔️"))
        add(["girl", "girls", "woman", "women", "lady"], .emoji("👧"))
        add(["boy", "boys", "man", "men", "guy"], .emoji("👦"))
        add(["mama", "mother", "mom", "mommy"], .emoji("👩"))
        add(["daddy", "father", "dad"], .emoji("👨"))
        add(["friend", "friends", "friendship"], .emoji("🤝"))
        add(["family", "children", "kids", "child"], .emoji("👪"))
        add(["ring", "wedding", "marry", "married"], .emoji("💍"))
        // Coloured symbols win over any older entry above.
        add(["dream", "dreams", "dreaming", "dreamed"], .emoji("💭"))
        add(["sleep", "sleeping", "asleep", "bed", "tired"], .emoji("😴"))
        add(["crazy", "wild", "insane"], .emoji("🤪"))
        add(["baby", "babe"], .emoji("👶"))
        add(["hope", "rainbow"], .emoji("🌈"))
        add(["luck", "lucky"], .emoji("🍀"))
        add(["magic", "magical", "spell"], .emoji("🪄"))
        add(["wish", "wishes", "wishing"], .emoji("🌠"))
        add(["peace"], .emoji("☮️"))
        add(["freedom", "free", "liberty"], .emoji("🕊️"))
        add(["wait", "waiting", "waited"], .emoji("⏳"))

        // Sky & nature
        add(["sun", "sunshine", "sunny", "sunrise", "sunset"], .symbol("sun.max.fill"))
        add(["moon", "moonlight"], .symbol("moon.fill"))
        add(["star", "stars"], .symbol("star.fill"))
        add(["night", "tonight", "dark", "darkness", "midnight"], .symbol("moon.stars.fill"))
        add(["cloud", "clouds", "sky"], .symbol("cloud.fill"))
        add(["rain", "raining", "rainy"], .symbol("cloud.rain.fill"))
        add(["storm", "thunder", "lightning", "electric"], .symbol("bolt.fill"))
        add(["snow", "snowing", "winter", "ice", "cold", "frozen"], .symbol("snowflake"))
        add(["wind", "breeze", "blow", "blowing"], .symbol("wind"))
        add(["fire", "flame", "flames", "burn", "burning", "burned", "hot"], .symbol("flame.fill"))
        add(["world", "earth", "planet", "globe"], .symbol("globe"))
        add(["light", "lights", "shine", "shining", "bright", "glow", "sparkle", "shimmer"], .symbol("sparkles"))
        add(["leaf", "leaves", "green"], .symbol("leaf.fill"))
        add(["ocean", "sea", "wave", "waves", "water", "tide", "swim"], .emoji("🌊"))
        add(["river", "lake"], .emoji("🏞️"))
        add(["mountain", "mountains", "hill", "hills"], .emoji("⛰️"))
        add(["tree", "trees", "forest", "woods"], .emoji("🌲"))
        add(["flower", "flowers", "rose", "roses"], .emoji("🌹"))
        add(["spring", "blossom", "bloom"], .emoji("🌸"))
        add(["summer", "beach", "sand"], .emoji("🏖️"))
        add(["morning", "dawn", "day", "daylight"], .emoji("🌅"))
        add(["fall", "falling", "fell", "autumn"], .emoji("🍂"))
        add(["bird", "birds", "fly", "flying", "wings", "wing"], .emoji("🕊️"))
        add(["diamond", "diamonds", "jewel", "jewels"], .emoji("💎"))
        add(["gold", "golden"], .emoji("🪙"))

        // Body
        add(["eye", "eyes", "look", "looking", "watch", "watching", "see", "seen"], .symbol("eye.fill"))
        add(["hand", "hands", "touch", "touching", "hold", "holding"], .symbol("hand.raised.fill"))
        add(["lips", "mouth"], .emoji("👄"))
        add(["face"], .emoji("🙂"))
        add(["mind", "brain", "think", "thinking", "thought"], .emoji("🧠"))
        add(["soul", "spirit"], .emoji("✨"))
        add(["blood", "bleed", "bleeding"], .emoji("🩸"))
        add(["bone", "bones"], .emoji("🦴"))
        add(["strong", "strength", "power"], .emoji("💪"))

        // Movement & places
        add(["run", "running", "ran", "runs"], .symbol("figure.run"))
        add(["walk", "walking", "walked"], .symbol("figure.walk"))
        add(["dance", "dancing", "danced", "dancer"], .emoji("💃"))
        add(["car", "cars", "drive", "driving", "drove", "road", "highway", "ride", "riding"], .symbol("car.fill"))
        add(["plane", "airplane", "flight"], .symbol("airplane"))
        add(["train", "railroad"], .emoji("🚆"))
        add(["boat", "ship", "sail", "sailing"], .emoji("⛵"))
        add(["home", "house"], .symbol("house.fill"))
        add(["city", "town"], .emoji("🏙️"))
        add(["street", "streets"], .emoji("🛣️"))
        add(["bridge"], .emoji("🌉"))
        add(["door", "doors"], .emoji("🚪"))
        add(["window", "windows"], .emoji("🪟"))
        add(["room"], .emoji("🛋️"))

        // Music & party
        add(["music", "song", "songs", "sing", "singing", "sang", "melody", "tune", "sound"], .symbol("music.note"))
        add(["guitar"], .emoji("🎸"))
        add(["piano", "keys"], .emoji("🎹"))
        add(["drum", "drums", "beat", "beats"], .emoji("🥁"))
        add(["radio"], .emoji("📻"))
        add(["party", "club", "celebrate", "celebration"], .emoji("🎉"))
        add(["drink", "drinks", "drinking", "drunk", "wine", "whiskey", "beer", "bottle", "champagne"], .emoji("🍷"))
        add(["cigarette", "cigarettes", "smoke", "smoking"], .emoji("🚬"))
        add(["coffee"], .emoji("☕"))

        // Time
        add(["time", "clock", "hour", "hours", "minute", "minutes", "second", "seconds"], .symbol("clock.fill"))
        add(["forever", "always", "eternity", "eternal"], .emoji("♾️"))

        // Things
        add(["money", "cash", "dollar", "dollars", "rich", "pay", "paid"], .emoji("💵"))
        add(["phone", "call", "calling", "called"], .symbol("phone.fill"))
        add(["message", "messages", "text", "texting"], .symbol("message.fill"))
        add(["letter", "letters"], .emoji("✉️"))
        add(["key"], .symbol("key.fill"))
        add(["lock", "locked", "chain", "chains"], .symbol("lock.fill"))
        add(["gift", "present"], .symbol("gift.fill"))
        add(["bell", "bells", "ring"], .symbol("bell.fill"))
        add(["flag"], .symbol("flag.fill"))
        add(["dream", "dreams", "dreaming", "sleep", "sleeping", "asleep"], .symbol("moon.zzz.fill"))
        add(["money", "dollar", "dollars", "cash", "rich", "paid"], .symbol("dollarsign.circle.fill"))
        add(["king", "queen", "crown", "kingdom", "royal"], .symbol("crown.fill"))
        add(["diamond", "diamonds", "jewel", "gold", "golden"], .symbol("diamond.fill"))
        add(["rose", "roses", "flower", "flowers", "garden"], .symbol("camera.macro"))
        add(["tree", "trees", "forest", "woods"], .symbol("tree.fill"))
        add(["mountain", "mountains", "hill", "hills"], .symbol("mountain.2.fill"))
        add(["water", "ocean", "sea", "wave", "waves", "river", "swim", "drown", "drowning"], .symbol("water.waves"))
        add(["drop", "drops", "rain", "raindrop"], .symbol("drop.fill"))
        add(["bird", "birds", "fly", "flying", "flew", "wings", "wing"], .symbol("bird.fill"))
        add(["dance", "dancing", "danced", "dancer"], .symbol("figure.dance"))
        add(["guitar", "guitars"], .symbol("guitars.fill"))
        add(["microphone", "mic", "voice", "voices"], .symbol("mic.fill"))
        add(["headphones", "listen", "listening"], .symbol("headphones"))
        add(["bed", "bedroom", "pillow"], .symbol("bed.double.fill"))
        add(["umbrella"], .symbol("umbrella.fill"))
        add(["dog", "dogs", "cat", "cats", "puppy", "kitten"], .symbol("pawprint.fill"))
        add(["camera", "photo", "photograph", "picture", "pictures"], .symbol("camera.fill"))
        add(["coffee", "tea"], .symbol("cup.and.saucer.fill"))
        add(["wine", "drink", "drinks", "drinking", "drunk", "champagne"], .symbol("wineglass.fill"))
        add(["idea", "ideas", "think", "thinking", "thought", "mind"], .symbol("lightbulb.fill"))
        return t
    }()
}
