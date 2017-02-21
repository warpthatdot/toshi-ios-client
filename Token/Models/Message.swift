import Foundation
import NoChat

public class Message: NSObject, NOCChatItem {

    public var messageId: String = UUID().uuidString
    public var messageType: String = "Text"

    public var signalMessage: TSMessage

    public var attributedTitle: NSAttributedString?
    public var attributedSubtitle: NSAttributedString?

    public var title: String? {
        set {
            if let string = newValue {
                self.attributedTitle = NSAttributedString(string: string, attributes: [NSFontAttributeName: Theme.semibold(size: 15), NSForegroundColorAttributeName: Theme.incomingMessageTextColor])
            } else {
                self.attributedTitle = nil
            }
        }
        get {
            return self.attributedTitle?.string
        }
    }

    public var subtitle: String? {
        set {
            if let string = newValue {
                self.attributedSubtitle = NSAttributedString(string: string, attributes: [NSFontAttributeName: Theme.regular(size: 15), NSForegroundColorAttributeName: Theme.incomingMessageTextColor])
            } else {
                self.attributedSubtitle = nil
            }
        }
        get {
            return self.attributedSubtitle?.string
        }
    }

    public var senderId: String = ""
    public var date: Date

    public var isOutgoing: Bool = true
    public var isActionable: Bool

    public var deliveryStatus: TSOutgoingMessageState {
        get {
            return (self.signalMessage as? TSOutgoingMessage)?.messageState ?? .attemptingOut
        }
    }

    public var sofaWrapper: SofaWrapper

    public var isDisplayable: Bool {
        return [.message, .paymentRequest, .payment].contains(self.sofaWrapper.type)
    }

    var text: String {
        get {
            switch self.sofaWrapper.type {
            case .message:
                return (self.sofaWrapper as! SofaMessage).body
            case .paymentRequest:
                let body = (self.sofaWrapper as! SofaPaymentRequest).body
                if body.length > 0 {
                    return body
                }
                return "Payment requested without message."
            case .payment:
                return "Should be an empty string here but layout breaks for now."
            default:
                return self.sofaWrapper.content
            }
        }
    }

    public func uniqueIdentifier() -> String {
        return self.messageId
    }

    public func type() -> String {
        return self.messageType
    }

    init(sofaWrapper: SofaWrapper, signalMessage: TSMessage, date: Date? = nil, isOutgoing: Bool = true, shouldProcess: Bool = false) {
        self.sofaWrapper = sofaWrapper
        self.isOutgoing = isOutgoing
        self.signalMessage = signalMessage
        self.date = date ?? Date()
        self.isActionable = shouldProcess && !isOutgoing && (sofaWrapper.type == .paymentRequest)

        super.init()
    }
}