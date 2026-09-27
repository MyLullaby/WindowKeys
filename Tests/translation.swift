import Foundation

private func checkTranslationPayload() throws {
    let request = try TranslationPayload.request(text: "Hello\n\"world\"", model: "test/model")
    assert(request.url?.absoluteString == "http://127.0.0.1:8787/v1/chat/completions")
    assert(request.httpMethod == "POST")
    let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
    assert(body["model"] as? String == "test/model")
    assert(body["stream"] as? Bool == false)
    assert(body["tools"] == nil)
    let messages = body["messages"] as! [[String: String]]
    // 代理会覆盖 system 消息，因此只能发送一条 user 消息，且必须带上待翻译原文。
    assert(messages.count == 1)
    assert(messages[0]["role"] == "user")
    assert(messages[0]["content"]?.contains("Hello\n\"world\"") == true)
    let models = try TranslationPayload.models(from: Data(#"{"data":[{"id":"b"},{"id":"a"},{"id":"b"},{"id":""}]}"#.utf8))
    assert(models == ["a", "b"])
    let translated = try TranslationPayload.translation(from: Data(#"{"choices":[{"message":{"content":" 你好 "}}]}"#.utf8))
    assert(translated == "你好")
    for invalid in [#"{"choices":[]}"#, #"{"error":{"message":"failure"}}"#,
                    #"{"choices":[{"message":{"content":" "}}]}"#] {
        do {
            _ = try TranslationPayload.translation(from: Data(invalid.utf8))
            assertionFailure("Invalid response accepted")
        } catch { }
    }
    print("Translation payload checks passed")
}

try checkTranslationPayload()
