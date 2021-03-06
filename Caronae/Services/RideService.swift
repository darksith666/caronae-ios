import RealmSwift

class RideService {
    static let instance = RideService()
    private let api = CaronaeAPIHTTPSessionManager.instance
    
    private init() {
        // This prevents others from using the default '()' initializer for this class.
    }
    
    func getRides(page: Int, filterParameters: FilterParameters? = nil, success: @escaping (_ rides: [Ride], _ lastPage: Int) -> Void, error: @escaping (_ error: Error) -> Void) {
        
        api.get("/api/v1/rides?page=\(page)", parameters: filterParameters?.dictionary(), progress: nil, success: { _, responseObject in
            guard let response = responseObject as? [String: Any],
                let ridesJson = response["data"] as? [[String: Any]],
                let lastPage = response["last_page"] as? Int else {
                    error(CaronaeError.invalidResponse)
                    return
            }
            
            // Deserialize rides
            let rides = ridesJson.compactMap { Ride(JSON: $0) }
            success(rides, lastPage)
        }, failure: { _, err in
            NSLog("Failed to load rides: \(err.localizedDescription)")
            error(err)
        })
    }
    
    func getMyRides(success: @escaping (_ pending: Results<Ride>, _ active: Results<Ride>, _ offered: Results<Ride>) -> Void, error: @escaping (_ error: Error) -> Void) {
        guard let user = UserService.instance.user else {
            NSLog("Error: No userID registered")
            return
        }
        
        do {
            let realm = try Realm()
            let currentDate = Date()
            
            let futureRides = realm.objects(Ride.self).filter("date >= %@", currentDate)
            let pending = futureRides.filter("isPending == true").sorted(byKeyPath: "date")
            let offered = futureRides.filter("driver == %@ AND isActive == false", user).sorted(byKeyPath: "date")
            let active = realm.objects(Ride.self).filter("isActive == true").sorted(byKeyPath: "date")
            
            success(pending, active, offered)
        } catch let realmError {
            error(realmError)
        }
    }
    
    func updateMyRides(success: @escaping () -> Void, error: @escaping (_ error: Error) -> Void) {
        guard let user = UserService.instance.user else {
            NSLog("Error: No userID registered")
            return
        }
        
        api.get("/api/v1/users/\(user.id)/rides", parameters: nil, progress: nil, success: { _, responseObject in
            guard let jsonResponse = responseObject as? [String: Any],
                let pendingRidesJson = jsonResponse["pending_rides"] as? [[String: Any]],
                let activeRidesJson = jsonResponse["active_rides"] as? [[String: Any]],
                let offeredRidesJson = jsonResponse["offered_rides"] as? [[String: Any]] else {
                    error(CaronaeError.invalidResponse)
                    return
            }
            
            // Deserialize response
            let pendingRides = pendingRidesJson.compactMap { rideJson in
                let ride = Ride(JSON: rideJson)
                ride?.isPending = true
                return ride
            } as [Ride]
            
            let activeRides = activeRidesJson.compactMap { rideJson in
                let ride = Ride(JSON: rideJson)
                ride?.isActive = true
                return ride
            } as [Ride]
            
            let offeredRides = offeredRidesJson.compactMap { rideJson in
                return Ride(JSON: rideJson)
            } as [Ride]
        
            self.handlePendingRidesUpdate(pendingRides)
            self.handleActiveRidesUpdate(activeRides)
            self.handleOfferedRidesUpdate(offeredRides)
        
            success()
        }, failure: { _, err in
            NSLog("Error: Failed to update user's rides: \(err.localizedDescription)")
            error(err)
        })
    }
    
    private func handlePendingRidesUpdate(_ rides: [Ride]) {
        do {
            let realm = try Realm()
            // Clear rides previously marked as pending
            let previouslyPending = realm.objects(Ride.self).filter("isPending == true")
            try realm.write {
                previouslyPending.forEach { $0.isPending = false }
            }
            
            // Update pending rides
            try realm.write {
                realm.add(rides, update: true)
            }
        } catch let realmError {
            NSLog("Error: Failed to update pending rides: \(realmError.localizedDescription)")
        }
    }
    
    private func handleActiveRidesUpdate(_ rides: [Ride]) {
        do {
            let realm = try Realm()
            // Clear rides previously marked as active
            let previouslyActives = Array(realm.objects(Ride.self).filter("isActive == true"))
            try realm.write {
                previouslyActives.forEach { $0.isActive = false }
            }
            
            // Clear notifications for finished/canceled rides
            let currentActiveIDs = rides.map { $0.id }
            var previouslyActiveIDs = Set(previouslyActives.map { $0.id })
            previouslyActiveIDs.subtract(currentActiveIDs)
            previouslyActiveIDs.forEach { id in
                NotificationService.instance.clearNotifications(forRideID: id, of: [.chat, .rideJoinRequestAccepted])
            }
            
            // Update active rides
            try realm.write {
                realm.add(rides, update: true)
            }
        } catch let realmError {
            NSLog("Error: Failed to update active rides: \(realmError.localizedDescription)")
        }
    }
    
    private func handleOfferedRidesUpdate(_ rides: [Ride]) {
        do {
            let realm = try Realm()
            let currentDate = Date()
            let ridesInThePast = realm.objects(Ride.self).filter("date < %@ AND isActive == false", currentDate)
            
            // Clear notifications for inactive rides in the past
            ridesInThePast.forEach { ride in
                NotificationService.instance.clearNotifications(forRideID: ride.id)
            }
            
            // Delete inactive rides in the past
            try realm.write {
                ridesInThePast.forEach { ride in
                    realm.delete(ride)
                }
            }
            
            // Update offered rides
            try realm.write {
                realm.add(rides, update: true)
            }
        } catch let realmError {
            NSLog("Error: Failed to update offered rides: \(realmError.localizedDescription)")
        }
    }
    
    func getRide(withID id: Int, success: @escaping (_ ride: Ride, _ availableSlots: Int) -> Void, error: @escaping (_ error: CaronaeError) -> Void) {
        api.get("/api/v1/rides/\(id)", parameters: nil, progress: nil, success: { task, responseObject in
            guard let rideJson = responseObject as? [String: Any],
                let ride = Ride(JSON: rideJson),
                let availableSlots = rideJson["availableSlots"] as? Int else {
                    error(CaronaeError.invalidRide)
                    return
            }
            
            success(ride, availableSlots)
        }, failure: { task, err in
            NSLog("Failed to load ride with id \(id): \(err.localizedDescription)")
            
            var caronaeError: CaronaeError = .invalidResponse
            if let response = task?.response as? HTTPURLResponse {
                switch response.statusCode {
                case 404:
                    caronaeError = .invalidRide
                default:
                    caronaeError = .invalidResponse
                }
            }
            
            error(caronaeError)
        })
    }
    
    func getRidesHistory(success: @escaping (_ rides: [Ride]) -> Void, error: @escaping (_ error: Error) -> Void) {
        guard let user = UserService.instance.user else {
            NSLog("Error: No userID registered")
            return
        }
        
        api.get("/api/v1/users/\(user.id)/rides/history", parameters: nil, progress: nil, success: { _, responseObject in
            guard let jsonResponse = responseObject as? [String: Any],
                let ridesJson = jsonResponse["rides"] as? [[String: Any]] else {
                error(CaronaeError.invalidResponse)
                return
            }
            
            // Deserialize rides
            let rides = ridesJson.compactMap { Ride(JSON: $0) }
            success(rides)
        }, failure: { _, err in
            error(err)
        })
    }
    
    func getRequestersForRide(withID id: Int, success: @escaping (_ rides: [User]) -> Void, error: @escaping (_ error: Error) -> Void) {
        api.get("/api/v1/rides/\(id)/requests", parameters: nil, progress: nil, success: { _, responseObject in
            guard let usersJson = responseObject as? [[String: Any]] else {
                error(CaronaeError.invalidResponse)
                return
            }
            
            let users = usersJson.compactMap { User(JSON: $0) }
            success(users)
        }, failure: { _, err in
            error(err)
        })
    }

    func createRide(_ ride: Ride, success: @escaping () -> Void, error: @escaping (_ error: Error) -> Void) {
        api.post("/api/v1/rides", parameters: ride.toJSON(), progress: nil, success: { _, responseObject in
            guard let ridesJson = responseObject as? [[String: Any]] else {
                error(CaronaeError.invalidResponse)
                return
            }
            
            let user = UserService.instance.user!
            let rides = ridesJson.compactMap {
                let ride = Ride(JSON: $0)
                ride?.driver = user
                return ride
            } as [Ride]
            
            do {
                let realm = try Realm()
                try realm.write {
                    realm.add(rides, update: true)
                }
            } catch let realmError {
                error(realmError)
            }
            
            success()
        }, failure: { _, err in
            error(err)
        })
    }
    
    func finishRide(withID id: Int, success: @escaping () -> Void, error: @escaping (_ error: Error) -> Void) {
        api.post("/api/v1/rides/\(id)/finish", parameters: nil, progress: nil, success: { _, _ in
            do {
                let realm = try Realm()
                if let ride = realm.object(ofType: Ride.self, forPrimaryKey: id) {
                    try realm.write {
                        realm.delete(ride)
                    }
                    
                    NotificationService.instance.clearNotifications(forRideID: id)
                    self.updateMyRides(success: {}, error: { _ in })
                } else {
                    NSLog("Ride with id %d not found locally in user's rides", id)
                }
            } catch let realmError {
                error(realmError)
            }
            
            success()
        }, failure: { _, err in
            error(err)
        })
    }

    func leaveRide(withID id: Int, success: @escaping () -> Void, error: @escaping (_ error: Error) -> Void) {
        api.post("/api/v1/rides/\(id)/leave", parameters: nil, progress: nil, success: { _, _ in
            do {
                let realm = try Realm()
                if let ride = realm.object(ofType: Ride.self, forPrimaryKey: id) {
                    try realm.write {
                        realm.delete(ride)
                    }
                    
                    NotificationService.instance.clearNotifications(forRideID: id)
                } else {
                    NSLog("Rides with routine id %d not found locally in user's rides", id)
                }
            } catch let realmError {
                error(realmError)
            }
            
            success()
        }, failure: { _, err in
            error(err)
        })
    }
    
    func deleteRoutine(withID id: Int, success: @escaping () -> Void, error: @escaping (_ error: Error) -> Void) {
        api.delete("/ride/allFromRoutine/\(id)", parameters: nil, success: { _, _ in
            do {
                let realm = try Realm()
                let rides = realm.objects(Ride.self).filter("routineID == %@", id)
                if !rides.isEmpty {    
                    rides.forEach { ride in
                        NotificationService.instance.clearNotifications(forRideID: ride.id)
                    }
                    
                    try realm.write {
                        realm.delete(rides)
                    }
                } else {
                    NSLog("Ride with id %d not found locally in user's rides", id)
                }
            } catch let realmError {
                error(realmError)
            }
            
            success()
        }, failure: { _, err in
            error(err)
        })
    }
    
    func requestJoinOnRide(_ ride: Ride, success: @escaping () -> Void, error: @escaping (_ error: Error) -> Void) {
        api.post("/api/v1/rides/\(ride.id)/requests", parameters: nil, progress: nil, success: { _, _ in
            do {
                let realm = try Realm()
                try realm.write {
                    ride.isPending = true
                    realm.add(ride, update: true)
                }
            } catch let realmError {
                error(realmError)
            }
            
            success()
        }, failure: { _, err in
            error(err)
        })
    }
    
    func hasRequestedToJoinRide(withID id: Int) -> Bool {
        guard let ride = getRideFromRealm(withID: id), ride.isPending else {
            return false
        }
        
        return true
    }
    
    func getRideFromRealm(withID id: Int) -> Ride? {
        guard let realm = try? Realm(), let ride = realm.object(ofType: Ride.self, forPrimaryKey: id) else {
            return nil
        }
        
        return ride
    }
    
    func validateRideDate(ride: Ride, success: @escaping (_ valid: Bool, _ status: String) -> Void, error: @escaping (_ error: Error?) -> Void) {
        let dateFormatter = DateFormatter()
        dateFormatter.calendar = Calendar(identifier: .gregorian)
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "dd/MM/yyyy HH:mm:ss"
        let dateString = dateFormatter.string(from: ride.date).components(separatedBy: " ")
        
        let params = [
            "date": dateString.first!,
            "time": dateString.last!,
            "going": ride.going
            ] as [String: Any]
        
        api.get("/api/v1/rides/validateDuplicate", parameters: params, progress: nil, success: { _, responseObject in
            guard let response = responseObject as? [String: Any],
                let valid = response["valid"] as? Bool,
                let status = response["status"] as? String else {
                    error(nil)
                    return
            }
            
            success(valid, status)
        }, failure: { _, err in
            error(err)
        })
    }
    
    func answerRequestOnRide(withID rideID: Int, fromUser user: User, accepted: Bool, success: @escaping () -> Void, error: @escaping (_ error: Error) -> Void) {
        let params = [
            "userId": user.id,
            "accepted": accepted
        ] as [String: Any]
        
        api.put("/api/v1/rides/\(rideID)/requests", parameters: params, success: { _, _ in
            if accepted {
                do {
                    let realm = try Realm()
                    if let ride = realm.object(ofType: Ride.self, forPrimaryKey: rideID) {
                        try realm.write {
                            realm.add(user, update: true)
                            ride.riders.append(user)
                            ride.isActive = true
                        }
                    } else {
                        NSLog("Ride with id %d not found locally in user's rides", rideID)
                    }
                } catch let realmError {
                    error(realmError)
                }
            }

            success()
        }, failure: { _, err in
            error(err)
        })
    }
}
