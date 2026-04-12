//
//  SessionSeparatorView.swift
//  LanguageModelChatUI
//

import MarkdownView
import UIKit

final class SessionSeparatorView: MessageListRowView {
    private let leftLine = UIView()
    private let rightLine = UIView()
    private let label = UILabel()

    var title: String? {
        didSet { label.text = title }
    }

    override var theme: MarkdownTheme {
        didSet { updateStyle() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)

        label.textAlignment = .center
        label.numberOfLines = 1
        contentView.addSubview(leftLine)
        contentView.addSubview(rightLine)
        contentView.addSubview(label)
        updateStyle()
    }

    @available(*, unavailable)
    @MainActor required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func updateStyle() {
        label.textColor = theme.colors.body.withAlphaComponent(0.45)
        label.font = theme.fonts.footnote
        leftLine.backgroundColor = theme.colors.body.withAlphaComponent(0.18)
        rightLine.backgroundColor = theme.colors.body.withAlphaComponent(0.18)
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        label.sizeToFit()
        let labelWidth = min(label.intrinsicContentSize.width + 16, contentView.bounds.width * 0.6)
        let labelHeight = max(label.intrinsicContentSize.height, 14)
        let midY = contentView.bounds.height / 2
        let spacing: CGFloat = 8
        let lineThickness: CGFloat = 1 / UIScreen.main.scale

        label.frame = CGRect(
            x: (contentView.bounds.width - labelWidth) / 2,
            y: midY - labelHeight / 2,
            width: labelWidth,
            height: labelHeight
        )

        leftLine.frame = CGRect(
            x: 0,
            y: midY - lineThickness / 2,
            width: max(0, label.frame.minX - spacing),
            height: lineThickness
        )

        rightLine.frame = CGRect(
            x: label.frame.maxX + spacing,
            y: midY - lineThickness / 2,
            width: max(0, contentView.bounds.width - label.frame.maxX - spacing),
            height: lineThickness
        )
    }
}
