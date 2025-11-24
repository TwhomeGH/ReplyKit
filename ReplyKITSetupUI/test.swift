////
////  test.swift
////  liveAPP
////
////  Created by user on 2025/11/23.
////
//
//import os
//import Foundation
//
//
//func test(_ body: String) {
//
//    let urlString = userDefaults?.string(
//        forKey: "logURL"
//    ) ?? "http://192.168.0.242:3000/post"
//
//    guard let url = URL(string: urlString) else {
//        print("Invalid URL")
//        return
//    }
//
//    var request = URLRequest(url: url)
//    request.httpMethod = "POST"
//    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
//
//    let json: [String: Any] = [
//        "title": "test",
//        "body": body
//    ]
//
//    do {
//        request.httpBody = try JSONSerialization.data(withJSONObject: json, options: [])
//    } catch {
//        print("Failed to encode JSON:", error)
//        return
//    }
//
//    let task = URLSession.shared.dataTask(with: request) { data, response, error in
//        if let error = error {
//            print("Error:", error)
//            return
//        }
//        if let httpResponse = response as? HTTPURLResponse {
//            print("Status code:", httpResponse.statusCode)
//        }
//        if let data = data, let text = String(data: data, encoding: .utf8) {
//            print("Response:", text)
//        }
//    }
//
//    task.resume()
//}
