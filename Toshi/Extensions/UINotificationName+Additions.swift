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

extension NSNotification.Name {
    static let UserDidSignOut = NSNotification.Name(rawValue: "UserDidSignOut")
    static let ChatDatabaseCreated = NSNotification.Name(rawValue: "ChatDatabaseCreated")
    static let currentUserUpdated = NSNotification.Name(rawValue: "currentUserUpdated")
    static let userCreated = NSNotification.Name(rawValue: "userCreated")
    static let userLoggedIn = NSNotification.Name(rawValue: "userLoggedIn")
    static let localCurrencyUpdated = NSNotification.Name(rawValue: "localCurrencyUpdated")
}
