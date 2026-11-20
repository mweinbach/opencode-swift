import Testing
import OpenCodeCore

private let hex = MachineTestHelper.hex
private let toHex = MachineTestHelper.toHex
private let text = MachineTestHelper.bytes

@Suite("Machine crypto primitives (RFC / NIST vectors)")
struct MachineCryptoTests {
    @Test("SHA-256 and SHA-512 match FIPS 180-4 examples")
    func shaVectors() {
        #expect(toHex(MachineCrypto.sha256([])) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(toHex(MachineCrypto.sha256(text("abc"))) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(
            toHex(MachineCrypto.sha256(text("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")))
                == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        )
        #expect(
            toHex(MachineCrypto.sha512(text("abc")))
                == "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f"
        )
        #expect(
            toHex(MachineCrypto.sha512([]))
                == "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e"
        )
    }

    @Test("HMAC-SHA256 matches RFC 4231 test cases 1, 2 and 6")
    func hmacVectors() {
        #expect(
            toHex(MachineCrypto.hmacSHA256(key: [UInt8](repeating: 0x0b, count: 20), data: text("Hi There")))
                == "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"
        )
        #expect(
            toHex(MachineCrypto.hmacSHA256(key: text("Jefe"), data: text("what do ya want for nothing?")))
                == "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
        )
        #expect(
            toHex(MachineCrypto.hmacSHA256(
                key: [UInt8](repeating: 0xaa, count: 131),
                data: text("Test Using Larger Than Block-Size Key - Hash Key First")
            )) == "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54"
        )
    }

    @Test("X25519 matches RFC 7748 sections 5.2 and 6.1")
    func x25519Vectors() {
        #expect(
            toHex(MachineCrypto.x25519(
                scalar: hex("a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4"),
                point: hex("e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c")
            )) == "c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552"
        )
        let alice = hex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
        let bob = hex("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb")
        let alicePublic = MachineCrypto.x25519PublicKey(privateKey: alice)
        let bobPublic = MachineCrypto.x25519PublicKey(privateKey: bob)
        #expect(toHex(alicePublic) == "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a")
        #expect(toHex(bobPublic) == "de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f")
        let shared = "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742"
        #expect(toHex(MachineCrypto.x25519(scalar: alice, point: bobPublic)) == shared)
        #expect(toHex(MachineCrypto.x25519(scalar: bob, point: alicePublic)) == shared)
    }

    @Test("Ed25519 matches RFC 8032 section 7.1 tests 1 to 3")
    func ed25519Vectors() {
        let vectors: [(seed: String, publicKey: String, message: String, signature: String)] = [
            (
                "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
                "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
                "",
                "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b"
            ),
            (
                "4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb",
                "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c",
                "72",
                "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00"
            ),
            (
                "c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7",
                "fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025",
                "af82",
                "6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a"
            ),
        ]
        for vector in vectors {
            let seed = hex(vector.seed)
            let message = hex(vector.message)
            #expect(toHex(MachineCrypto.ed25519PublicKey(seed: seed)) == vector.publicKey)
            let signature = MachineCrypto.ed25519Sign(seed: seed, message: message)
            #expect(toHex(signature) == vector.signature)
            #expect(MachineCrypto.ed25519Verify(publicKey: hex(vector.publicKey), message: message, signature: signature))
            var forged = signature
            forged[0] ^= 1
            #expect(!MachineCrypto.ed25519Verify(publicKey: hex(vector.publicKey), message: message, signature: forged))
            #expect(!MachineCrypto.ed25519Verify(publicKey: hex(vector.publicKey), message: message + [0], signature: signature))
        }
    }

    @Test("Ed25519 verification refuses a non-canonical S")
    func ed25519NonCanonicalS() {
        let seed = hex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
        let publicKey = MachineCrypto.ed25519PublicKey(seed: seed)
        var signature = MachineCrypto.ed25519Sign(seed: seed, message: [])
        // S + L encodes the same scalar but is not below L.
        let order: [UInt8] = hex("edd3f55c1a631258d69cf7a2def9de1400000000000000000000000000000010")
        var carry = 0
        for i in 0..<32 {
            let sum = Int(signature[32 + i]) + Int(order[i]) + carry
            signature[32 + i] = UInt8(truncatingIfNeeded: sum)
            carry = sum >> 8
        }
        #expect(!MachineCrypto.ed25519Verify(publicKey: publicKey, message: [], signature: signature))
    }

    @Test("AES-256-GCM matches NIST GCM spec test cases 13, 14 and 16")
    func aesGCMVectors() {
        let zeroKey = [UInt8](repeating: 0, count: 32)
        let zeroNonce = [UInt8](repeating: 0, count: 12)
        #expect(toHex(MachineCrypto.aes256GCMSeal(key: zeroKey, nonce: zeroNonce, aad: [], plaintext: [])) == "530f8afbc74536b9a963b4f1c4cb738b")
        #expect(
            toHex(MachineCrypto.aes256GCMSeal(key: zeroKey, nonce: zeroNonce, aad: [], plaintext: [UInt8](repeating: 0, count: 16)))
                == "cea7403d4d606b6e074ec5d3baf39d18d0d1c8a799996bf0265b98b5d48ab919"
        )
        let key = hex("feffe9928665731c6d6a8f9467308308feffe9928665731c6d6a8f9467308308")
        let nonce = hex("cafebabefacedbaddecaf888")
        let plaintext = hex("d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a721c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b39")
        let aad = hex("feedfacedeadbeeffeedfacedeadbeefabaddad2")
        let sealed = MachineCrypto.aes256GCMSeal(key: key, nonce: nonce, aad: aad, plaintext: plaintext)
        #expect(
            toHex(sealed)
                == "522dc1f099567d07f47f37a32a84427d643a8cdcbfe5c0c97598a2bd2555d1aa8cb08e48590dbb3da7b08b1056828838c5f61e6393ba7a0abcc9f66276fc6ece0f4e1768cddf8853bb2d551b"
        )
        #expect(MachineCrypto.aes256GCMOpen(key: key, nonce: nonce, aad: aad, sealed: sealed) == plaintext)
        var tampered = sealed
        tampered[tampered.count - 1] ^= 0x80
        #expect(MachineCrypto.aes256GCMOpen(key: key, nonce: nonce, aad: aad, sealed: tampered) == nil)
        #expect(MachineCrypto.aes256GCMOpen(key: key, nonce: nonce, aad: [], sealed: sealed) == nil)
    }

    @Test("Base64 and base64url follow RFC 4648")
    func base64() {
        let cases: [(String, String, String)] = [
            ("", "", ""), ("f", "Zg==", "Zg"), ("fo", "Zm8=", "Zm8"), ("foo", "Zm9v", "Zm9v"),
            ("foob", "Zm9vYg==", "Zm9vYg"), ("fooba", "Zm9vYmE=", "Zm9vYmE"), ("foobar", "Zm9vYmFy", "Zm9vYmFy"),
        ]
        for (plain, standard, url) in cases {
            #expect(MachineCrypto.base64Encode(text(plain)) == standard)
            #expect(MachineCrypto.base64URLEncode(text(plain)) == url)
            #expect(MachineCrypto.base64Decode(standard) == text(plain))
            #expect(MachineCrypto.base64URLDecode(url) == text(plain))
        }
        #expect(MachineCrypto.base64URLEncode([0xfb, 0xff]) == "-_8")
        #expect(MachineCrypto.base64Encode([0xfb, 0xff]) == "+/8=")
        #expect(MachineCrypto.base64URLDecode("+/8") == nil)
        #expect(MachineCrypto.base64Decode("Zg=a") == nil)
        #expect(MachineCrypto.base64Decode("Z") == nil)
    }
}
