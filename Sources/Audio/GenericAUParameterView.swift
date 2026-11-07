import AppKit
import AudioToolbox

@MainActor
final class GenericAUParameterView: NSView {
    private struct Row {
        let parameter: AUParameter
        let slider: NSSlider
        let valueLabel: NSTextField
    }

    private let parameterTree: AUParameterTree
    private let valueFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 6
        return formatter
    }()
    private var rows: [Row] = []
    private var observerToken: AUParameterObserverToken?

    init(parameterTree: AUParameterTree) {
        self.parameterTree = parameterTree
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildRows()
        observerToken = parameterTree.token(byAddingParameterObserver: { [weak self] address, value in
            Task { @MainActor [weak self] in
                self?.updateParameter(address: address, value: value)
            }
        })
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let observerToken {
            parameterTree.removeParameterObserver(observerToken)
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 760, height: max(CGFloat(rows.count * 40 + 24), 80))
    }

    private func buildRows() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
        ])

        for parameter in parameterTree.allParameters {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 12
            row.translatesAutoresizingMaskIntoConstraints = false

            let nameLabel = NSTextField(labelWithString: parameter.displayName)
            nameLabel.font = .systemFont(ofSize: 15, weight: .semibold)
            nameLabel.lineBreakMode = .byTruncatingTail
            nameLabel.translatesAutoresizingMaskIntoConstraints = false

            let valueLabel = NSTextField(labelWithString: formatValue(parameter.value))
            valueLabel.alignment = .right
            valueLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            valueLabel.translatesAutoresizingMaskIntoConstraints = false

            let slider = NSSlider(value: Double(parameter.value), minValue: Double(parameter.minValue), maxValue: Double(parameter.maxValue), target: self, action: #selector(sliderChanged(_:)))
            slider.isContinuous = true
            slider.tag = rows.count
            slider.translatesAutoresizingMaskIntoConstraints = false

            row.addArrangedSubview(nameLabel)
            row.addArrangedSubview(valueLabel)
            row.addArrangedSubview(slider)
            stack.addArrangedSubview(row)

            NSLayoutConstraint.activate([
                row.widthAnchor.constraint(equalTo: stack.widthAnchor),
                nameLabel.widthAnchor.constraint(equalToConstant: 170),
                valueLabel.widthAnchor.constraint(equalToConstant: 76),
                slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 260)
            ])
            rows.append(Row(parameter: parameter, slider: slider, valueLabel: valueLabel))
        }
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        guard rows.indices.contains(sender.tag) else { return }
        let row = rows[sender.tag]
        let value = AUValue(sender.doubleValue)
        row.parameter.setValue(value, originator: observerToken)
        updateParameter(address: row.parameter.address, value: value)
    }

    private func updateParameter(address: AUParameterAddress, value: AUValue) {
        guard let row = rows.first(where: { $0.parameter.address == address }) else { return }
        row.slider.doubleValue = Double(value)
        row.valueLabel.stringValue = formatValue(value)
    }

    private func formatValue(_ value: AUValue) -> String {
        valueFormatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}
