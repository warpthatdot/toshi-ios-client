// Copyright (c) 2018 Token Browser, Inc
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

import UIKit
import SweetFoundation
import Teapot
import Haneke

typealias ProfilesFrontPageResults = (_ sections: [ProfilesFrontPageSection]?, _ error: ToshiError?) -> Void
typealias SearchedProfilesResults = (_ profiles: [Profile]?, _ type: String?, _ error: ToshiError?) -> Void
typealias ProfileResults = (_ profiles: [Profile]?, _ error: ToshiError?) -> Void
typealias ProfileResult = (_ profile: Profile?, _ error: ToshiError?) -> Void

@objc enum UserRegisterStatus: Int {
    case existing = 0, registered, failed
}

final class IDAPIClient {

    enum Keys {
        static let profilesFrontPageCacheKey = "ProfilesFrontPageCacheKey"
    }

    static let shared: IDAPIClient = IDAPIClient()

    static let usernameValidationPattern = "^[a-zA-Z][a-zA-Z0-9_]+$"

    static let didFetchContactInfoNotification = Notification.Name(rawValue: "DidFetchContactInfo")

    static let allowedSearchTermCharacters = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: ":/?#[]@!$&'()*+,;= "))

    var teapot: Teapot

    private let profilesFrontPageCache = Shared.dataCache

    private var searchProfilesTask: URLSessionTask?

    private lazy var updateOperationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 2 //we update collections under "storedContactKey" and "favoritesCollectionKey" concurrently
        queue.name = "Update contacts queue"

        return queue
    }()

    var baseURL: URL

    convenience init(teapot: Teapot, cacheEnabled: Bool = true) {
        self.init()
        self.teapot = teapot
    }

    private init() {
        baseURL = URL(string: ToshiIdServiceBaseURLPath)!
        teapot = Teapot(baseURL: baseURL)
    }

    /// We use a background queue and a semaphore to ensure we only update the UI
    /// once all the contacts have been processed.
    func updateContacts() {
        updateOperationQueue.cancelAllOperations()

        updateContacts(for: ProfileKeys.storedContactKey)
        updateContacts(for: ProfileKeys.favoritesCollectionKey)
    }

    private func updateContacts(for collectionKey: String) {
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self] in
            guard let contactsData = Yap.sharedInstance.retrieveObjects(in: collectionKey) as? [Data] else { return }

            for contactData in contactsData {
                guard let dictionary = try? JSONSerialization.jsonObject(with: contactData, options: []) else { continue }

                if let dictionary = dictionary as? [String: Any], let toshiId = dictionary[ProfileKeys.toshiId] as? String {

                    self?.findContact(name: toshiId) { profile, _ in

                        if let updatedProfile = profile {
                            Yap.sharedInstance.insert(object: updatedProfile.data, for: updatedProfile.toshiId, in: collectionKey)
                        }
                    }
                }
            }
        }

        updateOperationQueue.addOperation(operation)
    }

    func updateContacts(with identifiers: [String]) {
        fetchUsers(with: identifiers) { profiles, _ in

            guard let fetchedProfiles = profiles else { return }

            for profile in fetchedProfiles {
                if !Yap.sharedInstance.containsObject(for: profile.toshiId, in: ProfileKeys.storedContactKey) {
                    Yap.sharedInstance.insert(object: profile.data, for: profile.toshiId, in: ProfileKeys.storedContactKey)
                }

                SessionManager.shared.profilesManager.updateProfile(profile)
            }
        }
    }

    func updateContact(with identifier: String) {
        findContact(name: identifier) { updatedProfile, _ in
            if let updatedProfile = updatedProfile {

                Yap.sharedInstance.insert(object: updatedProfile.data, for: updatedProfile.toshiId, in: ProfileKeys.storedContactKey)

                guard identifier != Cereal.shared.address else {
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: .currentUserUpdated, object: nil)
                    }
                    return
                }

                SessionManager.shared.profilesManager.updateProfile(updatedProfile)
            }
        }
    }

    func fetchTimestamp(_ completion: @escaping ((_ timestamp: Int?, _ error: ToshiError?) -> Void)) {

        self.teapot.get("/v1/timestamp") { result in
            switch result {
            case .success(let json, _):
                guard let json = json?.dictionary, let timestamp = json["timestamp"] as? Int else {
                    DLog("No response json - Fetch timestamp")
                    completion(nil, .invalidResponseJSON)
                    return
                }

                completion(timestamp, nil)
            case .failure(_, _, let error):
                completion(nil, ToshiError(withTeapotError: error))
            }
        }
    }

    func migrateCurrentUserIfNeeded() {
        guard let user = Profile.current, user.paymentAddress != Cereal.shared.paymentAddress else {
            return
        }

        guard var userDict = user.dictionary else { return }
        userDict[ProfileKeys.paymentAddress] = Cereal.shared.paymentAddress

        updateUser(userDict) { _, _ in }
    }

    func registerUserIfNeeded(_ success: @escaping ((_ userRegisterStatus: UserRegisterStatus) -> Void)) {
        retrieveUser(username: Cereal.shared.address) { profile, _ in

            guard profile == nil else {
                success(.existing)
                return
            }

            self.fetchTimestamp { timestamp, error in
                guard let timestamp = timestamp else {
                    success(.failed)
                    return
                }
                
                let cereal = Cereal.shared
                let path = "/v2/user"
                let parameters = [
                    "payment_address": cereal.paymentAddress
                ]

                guard let data = try? JSONSerialization.data(withJSONObject: parameters, options: []), let parametersString = String(data: data, encoding: .utf8) else {
                    success(.failed)
                    return
                }

                let hashedParameters = cereal.sha3WithID(string: parametersString)
                let signature = "0x\(cereal.signWithID(message: "POST\n\(path)\n\(timestamp)\n\(hashedParameters)"))"

                let fields: [String: String] = ["Token-ID-Address": cereal.address, "Token-Signature": signature, "Token-Timestamp": String(timestamp)]

                let json = RequestParameter(parameters)

                self.teapot.post(path, parameters: json, headerFields: fields) { result in
                    var status: UserRegisterStatus = .failed

                    switch result {
                    case .success(let json, let response):
                        guard response.statusCode == 200 else { return }

                        guard let data = json?.data else {
                           assertionFailure("No data from registration request response")
                            return
                        }

                        let profile: Profile
                        do {
                            let jsonDecoder = JSONDecoder()
                            profile = try jsonDecoder.decode(Profile.self, from: data)
                            Profile.setupCurrentProfile(profile)
                        } catch {
                            assertionFailure("Can't decode curent user profile from register request response")
                        }

                        status = .registered
                    case .failure(_, _, let error):
                        DLog("\(error)")
                        status = .failed
                    }

                    DispatchQueue.main.async {
                        success(status)
                    }
                }
            }
        }
    }

    func updateAvatar(_ avatar: UIImage, completion: @escaping ((_ success: Bool, _ error: ToshiError?) -> Void)) {
        fetchTimestamp { timestamp, error in
            guard let timestamp = timestamp else {
                DispatchQueue.main.async {
                    completion(false, error)
                }
                return
            }

            let cereal = Cereal.shared
            let path = "/v2/user"
            let boundary = "teapot.boundary"
            let payload = self.teapot.multipartData(from: avatar, boundary: boundary, filename: "avatar.png")
            let hashedPayload = cereal.sha3WithID(data: payload)
            let signature = "0x\(cereal.signWithID(message: "PUT\n\(path)\n\(timestamp)\n\(hashedPayload)"))"

            let fields: [String: String] = ["Token-ID-Address": cereal.address, "Token-Signature": signature, "Token-Timestamp": String(timestamp), "Content-Length": String(describing: payload.count), "Content-Type": "multipart/form-data; boundary=\(boundary)"]
            let json = RequestParameter(payload)

            self.teapot.put(path, parameters: json, headerFields: fields) { result in
                var succeeded = false
                var toshiError: ToshiError?

                switch result {
                case .success(let json, _):
                    guard let userDict = json?.dictionary else {
                        DispatchQueue.main.async {
                            completion(false, .invalidResponseJSON)
                        }
                        return
                    }

                    if let path = userDict["avatar"] as? String {
                        AvatarManager.shared.refreshAvatar(at: path)
                        Profile.current?.updateAvatarPath(path)
                    }

                    succeeded = true
                case .failure(_, _, let error):
                    DLog("\(error)")
                    toshiError = ToshiError(withTeapotError: error)
                }

                DispatchQueue.main.async {
                    completion(succeeded, toshiError)
                }
            }
        }
    }

    func updateUser(_ userDict: [String: Any], completion: @escaping ((_ success: Bool, _ error: ToshiError?) -> Void)) {
        fetchTimestamp { timestamp, error in
            guard let timestamp = timestamp else {
                DispatchQueue.main.async {
                    completion(false, error)
                }
                return
            }

            let cereal = Cereal.shared
            let path = "/v2/user"

            guard let payload = try? JSONSerialization.data(withJSONObject: userDict, options: []), let payloadString = String(data: payload, encoding: .utf8) else {
                DispatchQueue.main.async {
                    completion(false, .invalidPayload)
                }
                return
            }

            let hashedPayload = cereal.sha3WithID(string: payloadString)
            let signature = "0x\(cereal.signWithID(message: "PUT\n\(path)\n\(timestamp)\n\(hashedPayload)"))"

            let fields: [String: String] = ["Token-ID-Address": cereal.address, "Token-Signature": signature, "Token-Timestamp": String(timestamp)]
            let json = RequestParameter(userDict)

            self.teapot.put("/v2/user", parameters: json, headerFields: fields) { result in
                var succeeded = false
                var toshiError: ToshiError?

                switch result {
                case .success(let json, let response):
                    guard response.statusCode == 200 else {
                        DLog("Invalid response - Update user")
                        DispatchQueue.main.async {
                            completion(false, ToshiError(withType: .invalidResponseStatus, description: "User could not be updated", responseStatus: response.statusCode))
                        }
                        return
                    }

                    guard let data = json?.data else {
                        DispatchQueue.main.async {
                            completion(false, .invalidPayload)
                        }
                        return
                    }

                    let profile: Profile
                    do {
                        let jsonDecoder = JSONDecoder()
                        profile = try jsonDecoder.decode(Profile.self, from: data)
                    } catch {
                        DispatchQueue.main.async {
                            completion(false, .invalidResponseJSON)
                        }
                        return
                    }

                    Profile.setupCurrentProfile(profile)

                    succeeded = true
                case .failure(let json, _, let error):

                    if let errors = json?.dictionary?["errors"] as? [[String: Any]], let errorMessage = (errors.first?["message"] as? String) {
                        toshiError = ToshiError(withTeapotError: error, errorDescription: errorMessage)
                    } else {
                        toshiError = ToshiError(withTeapotError: error)
                    }

                }

                DispatchQueue.main.async {
                    completion(succeeded, toshiError)
                }
            }
        }
    }

    /// Used to retrieve the server-side data for the user.
    ///
    /// - Parameters:
    ///   - username: username of id address
    ///   - completion: called on completion
    func retrieveUser(username: String, completion: ProfileResult? = nil) {

        self.teapot.get("/v2/user/\(username)", headerFields: ["Token-Timestamp": String(Int(Date().timeIntervalSince1970))]) { result in

            var profile: Profile?

            switch result {
            case .success(let json, _):
                guard let data = json?.data else {
                    DispatchQueue.main.async {
                        completion?(nil, .invalidPayload)
                    }
                    return
                }

                do {
                    let jsonDecoder = JSONDecoder()
                    profile = try jsonDecoder.decode(Profile.self, from: data)
                } catch {
                    DispatchQueue.main.async {
                        completion?(nil, .invalidResponseJSON)
                    }
                    return
                }

            case .failure(_, _, let error):
                DLog(error.localizedDescription)
            }

            DispatchQueue.main.async {
                completion?(profile, nil)
            }
        }
    }

    func findContact(name: String, completion: @escaping ProfileResult) {

        self.teapot.get("/v2/user/\(name)") { result in

            switch result {
            case .success(let json, _):

                guard let data = json?.data else {
                    DispatchQueue.main.async {
                        completion(nil, .invalidPayload)
                    }
                    return
                }

                let profile: Profile
                do {
                    let jsonDecoder = JSONDecoder()
                    profile = try jsonDecoder.decode(Profile.self, from: data)
                } catch {
                    DispatchQueue.main.async {
                        completion(nil, .invalidResponseJSON)
                    }
                    return
                }

                DispatchQueue.main.async {
                    completion(profile, nil)
                }

            case .failure(_, _, let error):
                DispatchQueue.main.async {
                    completion(nil, .invalidResponseJSON)
                }
                DLog(error.localizedDescription)
            }
        }
    }

    func searchContacts(name: String, completion: @escaping ProfileResults) {
        let query = name.addingPercentEncoding(withAllowedCharacters: IDAPIClient.allowedSearchTermCharacters) ?? name
        self.teapot.get("/v2/search?query=\(query)") { result in
            var profiles: [Profile]?
            var resultError: ToshiError?

            switch result {
            case .success(let json, _):
                guard let data = json?.data else {
                    DispatchQueue.main.async {
                        completion(nil, .invalidPayload)
                    }
                    return
                }

                let responseData: SearchedProfilesData
                do {
                    let jsonDecoder = JSONDecoder()
                    responseData = try jsonDecoder.decode(SearchedProfilesData.self, from: data)
                } catch {
                    DispatchQueue.main.async {
                        completion(nil, .invalidResponseJSON)
                    }
                    return
                }

                profiles = responseData.profiles.filter { $0.toshiId != Cereal.shared.address }
                responseData.profiles.forEach { AvatarManager.shared.downloadAvatar(for: String.contentsOrEmpty(for: $0.avatar)) }

            case .failure(_, _, let error):
                DLog(error.localizedDescription)
                resultError = ToshiError(withTeapotError: error)
            }

            DispatchQueue.main.async {
                completion(profiles, resultError)
            }
        }
    }
    
    /// Fetches the TokenUser details for an array of raw addresses.
    ///
    /// - Parameters:
    ///   - addresses: An array of raw addresses as strings.
    ///                NOTE: Requests with more than 1000 addresses will error in dev and only fetch the first 1000 in prod - requests this large should be broken into multiple requests.
    ///   - completion: The completion closure to fire when the request completes.
    ///                 - users: The fetched users, or nil.
    ///                 - error: Any error encountered, or nil.
    func fetchUsers(with addresses: [String], completion: @escaping ProfileResults) {
        guard addresses.count > 0 else {
            // No addresses to actually fetch = no users to return.
            completion([], nil)
            
            return
        }
        
        // Due to limits on URL length, you can't request more than 1000 users at once.
        // https://github.com/toshiapp/toshi-ios-client/pull/674#discussion_r159873041
        let addressCountLimit = 1000
        
        var addressesToFetch = addresses
        if addresses.count > addressCountLimit {
            assertionFailure("Please break this request into batches of less than \(addressCountLimit).")
            
            // In prod: Fetch the first batch up to the limit.
            addressesToFetch = Array(addresses[0..<addressCountLimit])
        }
        
        let fetchString = "?toshi_id=" + addressesToFetch.joined(separator: "&toshi_id=")

        self.teapot.get("/v2/search\(fetchString)") { result in

            var profiles: [Profile]?
            var resultError: ToshiError?

            switch result {
            case .success(let json, _):
                guard let data = json?.data else {
                    DispatchQueue.main.async {
                        completion(nil, .invalidPayload)
                    }
                    return
                }

                let responseData: SearchedProfilesData
                do {
                    let jsonDecoder = JSONDecoder()
                    responseData = try jsonDecoder.decode(SearchedProfilesData.self, from: data)
                } catch {
                    DispatchQueue.main.async {
                        completion(nil, .invalidResponseJSON)
                    }
                    return
                }

                profiles = responseData.profiles
                responseData.profiles.forEach { AvatarManager.shared.downloadAvatar(for: String.contentsOrEmpty(for: $0.avatar)) }

            case .failure(_, _, let error):
                DLog(error.localizedDescription)
                resultError = ToshiError(withTeapotError: error)
            }

            DispatchQueue.main.async {
                completion(profiles, resultError)
            }
        }
    }

    func findUserWithPaymentAddress(_ paymentAddress: String, completion: @escaping SearchedProfilesResults) {
        guard EthereumAddress.validate(paymentAddress) else {
            assertionFailure("Bad payment address while trying to search for a user \(paymentAddress).")
            completion(nil, nil, nil)
            return
        }

        self.teapot.get("/v2/search?payment_address=\(paymentAddress)") { result in

            var profiles: [Profile]?
            var resultError: ToshiError?

            switch result {
            case .success(let json, _):
                guard let data = json?.data else {
                    DispatchQueue.main.async {
                        completion(nil, nil, .invalidPayload)
                    }
                    return
                }

                let responseData: SearchedProfilesData
                do {
                    let jsonDecoder = JSONDecoder()
                    responseData = try jsonDecoder.decode(SearchedProfilesData.self, from: data)
                } catch {
                    DispatchQueue.main.async {
                        completion(nil, nil, .invalidResponseJSON)
                    }
                    return
                }

                profiles = responseData.profiles
                responseData.profiles.forEach { AvatarManager.shared.downloadAvatar(for: String.contentsOrEmpty(for: $0.avatar)) }

            case .failure(_, _, let error):
                DLog(error.localizedDescription)
                resultError = ToshiError(withTeapotError: error)
            }

            DispatchQueue.main.async {
                completion(profiles, nil, resultError)
            }
        }
    }

    func reportUser(address: String, reason: String = "", completion: @escaping ((_ success: Bool, _ error: ToshiError?) -> Void) = { (Bool, String) in }) {
        fetchTimestamp { timestamp, error in
            guard let timestamp = timestamp else {
                DispatchQueue.main.async {
                    completion(false, error)
                }
                return
            }

            let cereal = Cereal.shared
            let path = "/v1/report"

            let payload = [
                "token_id": address,
                "details": reason
            ]

            guard let payloadData = try? JSONSerialization.data(withJSONObject: payload, options: []), let payloadString = String(data: payloadData, encoding: .utf8) else {
                DispatchQueue.main.async {
                    completion(false, .invalidPayload)
                }
                return
            }

            let hashedPayload = cereal.sha3WithID(string: payloadString)
            let signature = "0x\(cereal.signWithID(message: "POST\n\(path)\n\(timestamp)\n\(hashedPayload)"))"

            let fields: [String: String] = ["Token-ID-Address": cereal.address, "Token-Signature": signature, "Token-Timestamp": String(timestamp)]
            let json = RequestParameter(payload)

            self.teapot.post(path, parameters: json, headerFields: fields) { result in
                var succeeded = false
                var toshiError: ToshiError?

                switch result {
                case .success(_, let response):
                    guard response.statusCode == 204 else {
                        DLog("Invalid response - Report user")
                        DispatchQueue.main.async {
                            completion(false, ToshiError(withType: .invalidResponseStatus, description: "Request to report user could not be completed", responseStatus: response.statusCode))
                        }
                        return
                    }

                    succeeded = true
                case .failure(let json, _, let error):
                    if let errors = json?.dictionary?["errors"] as? [[String: Any]], let errorMessage = errors.first?["message"] as? String {
                        toshiError = ToshiError(withTeapotError: error, errorDescription: errorMessage)
                    } else {
                        toshiError = ToshiError(withTeapotError: error)
                    }
                }

                DispatchQueue.main.async {
                    completion(succeeded, toshiError)
                }
            }
        }
    }

    func adminLogin(loginToken: String, completion: @escaping ((_ success: Bool, _ error: ToshiError?) -> Void) = { (Bool, String) in }) {
        fetchTimestamp { timestamp, error in
            guard let timestamp = timestamp else {
                DispatchQueue.main.async {
                    completion(false, error)
                }
                return
            }

            let cereal = Cereal.shared
            let path = "/v1/login/\(loginToken)"

            let signature = "0x\(cereal.signWithID(message: "GET\n\(path)\n\(timestamp)\n"))"

            let fields: [String: String] = ["Token-ID-Address": cereal.address, "Token-Signature": signature, "Token-Timestamp": String(timestamp)]

            self.teapot.get(path, headerFields: fields) { result in
                var succeeded = false
                var toshiError: ToshiError?

                switch result {
                case .success(_, let response):
                    guard response.statusCode == 204 else {
                        DLog("Invalid response - Login")
                        DispatchQueue.main.async {
                            completion(false, ToshiError(withType: .invalidResponseStatus, description: "Request to login as admin could not be completed", responseStatus: response.statusCode))
                        }
                        return
                    }

                    succeeded = true
                case .failure(let json, _, let error):
                    if let errors = json?.dictionary?["errors"] as? [[String: Any]], let errorMessage = (errors.first?["message"] as? String) {
                        toshiError = ToshiError(withTeapotError: error, errorDescription: errorMessage)
                    } else {
                        toshiError = ToshiError(withTeapotError: error)
                    }
                }

                DispatchQueue.main.async {
                    completion(succeeded, toshiError)
                }
            }
        }
    }

    /// Gets Users, bots and groups search sectioned frontpage. Does cache
    ///
    /// - Parameters:
    ///   - completion: The completion closure to execute when the request completes
    ///                 - frontpage sections: A list of sections, or nil
    ///                 - toshiError: A toshiError if any error was encountered, or nil
    func fetchProfilesFrontPage(completion: @escaping ProfilesFrontPageResults) {

        profilesFrontPageCache.fetch(key: Keys.profilesFrontPageCacheKey).onSuccess { data in
            var frontPage: ProfilesFrontPage?
            do {
                let jsonDecoder = JSONDecoder()
                frontPage = try jsonDecoder.decode(ProfilesFrontPage.self, from: data)
            } catch { return }

            DispatchQueue.main.async {
                completion(frontPage?.sections, nil)
            }
        }

        let path = "/v2/search"
        teapot.get(path) { [weak self ] result in
            var sections: [ProfilesFrontPageSection]?
            var resultError: ToshiError?

            switch result {
            case .success(let json, _):
                guard let data = json?.data else {
                    DispatchQueue.main.async {
                        completion(nil, .invalidPayload)
                    }
                    return
                }

                self?.profilesFrontPageCache.set(value: data, key: Keys.profilesFrontPageCacheKey)

                let frontPage: ProfilesFrontPage
                do {
                    let jsonDecoder = JSONDecoder()
                    frontPage = try jsonDecoder.decode(ProfilesFrontPage.self, from: data)
                } catch {
                    DispatchQueue.main.async {
                        completion(nil, .invalidResponseJSON)
                    }
                    return
                }

                frontPage.sections.forEach({ section in
                    section.profiles.forEach { AvatarManager.shared.downloadAvatar(for: String.contentsOrEmpty(for: $0.avatar)) }
                })

                sections = frontPage.sections
            case .failure(_, _, let error):
                DLog(error.localizedDescription)
                resultError = ToshiError(withTeapotError: error)
            }

            DispatchQueue.main.async {
                completion(sections, resultError)
            }
        }
    }

    /// Searches profiles of a given type and optional search text.
    ///
    /// - Parameters:
    ///   - type: stringtype of searched objects - user, bot or groupbot.
    ///   - searchText: optional search text.
    ///   - completion: The completion closure to execute when the request completes
    ///                 - profiles: A list of profiles, or nil
    ///                 - type: Requested type
    ///                 - toshiError: A toshiError if any error was encountered, or nil
    func searchProfilesOfType(_ type: String, for searchText: String? = nil, completion: @escaping SearchedProfilesResults) {

        let path = createPathFor(type, with: searchText)

        searchProfilesTask?.cancel()

        searchProfilesTask = teapot.get(path) { result in

            var profiles: [Profile]?
            var resultError: ToshiError?

            switch result {
            case .success(let json, _):
                guard let data = json?.data else {
                    DispatchQueue.main.async {
                        completion(nil, type, .invalidPayload)
                    }
                    return
                }

                let responseData: SearchedProfilesData
                do {
                    let jsonDecoder = JSONDecoder()
                    responseData = try jsonDecoder.decode(SearchedProfilesData.self, from: data)
                } catch {
                    DispatchQueue.main.async {
                        completion(nil, type, .invalidResponseJSON)
                    }
                    return
                }

                profiles = responseData.profiles
                responseData.profiles.forEach { AvatarManager.shared.downloadAvatar(for: String.contentsOrEmpty(for: $0.avatar)) }

            case .failure(_, _, let error):
                DLog(error.localizedDescription)
                resultError = ToshiError(withTeapotError: error)
            }

            DispatchQueue.main.async {
                completion(profiles, type, resultError)
            }
        }
    }

    func createPathFor(_ type: String, with searchText: String?) -> String {
        var path = "/v2/search?type=\(type)"
        if let query = searchText {
            path.append("&query=\(query)")
        }

        return path
    }
}
