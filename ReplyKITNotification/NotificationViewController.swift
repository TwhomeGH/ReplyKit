import UIKit
import UserNotifications
import UserNotificationsUI

class NotificationViewController: UIViewController, UNNotificationContentExtension {

    private let avatarImageView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFill
        iv.clipsToBounds = true
        iv.layer.cornerRadius = 25
        iv.translatesAutoresizingMaskIntoConstraints = false
        return iv
    }()

    private let appIconImageView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFit
        iv.clipsToBounds = true
        iv.layer.cornerRadius = 7
        iv.layer.borderWidth = 1.5
        iv.layer.borderColor = UIColor.white.cgColor
        iv.backgroundColor = .systemGray5
        iv.translatesAutoresizingMaskIntoConstraints = false
        return iv
    }()

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.font = UIFont.boldSystemFont(ofSize: 15)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let bodyLabel: UILabel = {
        let label = UILabel()
        label.font = UIFont.systemFont(ofSize: 13)
        label.textColor = .secondaryLabel
        label.numberOfLines = 3
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
    }

    private func setupUI() {
        view.addSubview(avatarImageView)
        view.addSubview(appIconImageView)
        view.addSubview(titleLabel)
        view.addSubview(bodyLabel)

        NSLayoutConstraint.activate([
            avatarImageView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            avatarImageView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            avatarImageView.widthAnchor.constraint(equalToConstant: 50),
            avatarImageView.heightAnchor.constraint(equalToConstant: 50),

            appIconImageView.leadingAnchor.constraint(equalTo: avatarImageView.trailingAnchor, constant: -14),
            appIconImageView.bottomAnchor.constraint(equalTo: avatarImageView.bottomAnchor),
            appIconImageView.widthAnchor.constraint(equalToConstant: 22),
            appIconImageView.heightAnchor.constraint(equalToConstant: 22),

            titleLabel.leadingAnchor.constraint(equalTo: appIconImageView.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            titleLabel.topAnchor.constraint(equalTo: avatarImageView.topAnchor, constant: 2),

            bodyLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            bodyLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            bodyLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            bodyLabel.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -16)
        ])
    }

    func didReceive(_ notification: UNNotification) {
        let content = notification.request.content
        titleLabel.text = content.title
        bodyLabel.text = content.body

        if let attachment = content.attachments.first {
            let didStartAccess = attachment.url.startAccessingSecurityScopedResource()
            if let data = try? Data(contentsOf: attachment.url) {
                avatarImageView.image = UIImage(data: data)
            }
            if didStartAccess {
                attachment.url.stopAccessingSecurityScopedResource()
            }
        }
        //Mark: - Load App Icon
        if let appIcon = UIImage(named: "AppIcon60x60@2x") ?? UIImage(named: "AppIcon76x76@2x") {
            appIconImageView.image = appIcon
        }
    }

}
