import ContactsUI
import SwiftUI

/// Lets the user pick a contact's name without granting WakeOnCue access to Contacts.
struct ContactNamePicker: UIViewControllerRepresentable {
  let onFinish: (String?) -> Void

  func makeUIViewController(context: Context) -> CNContactPickerViewController {
    let picker = CNContactPickerViewController()
    picker.delegate = context.coordinator
    picker.displayedPropertyKeys = [CNContactGivenNameKey, CNContactFamilyNameKey]
    return picker
  }

  func updateUIViewController(_ controller: CNContactPickerViewController, context: Context) {}

  func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

  final class Coordinator: NSObject, CNContactPickerDelegate {
    let onFinish: (String?) -> Void

    init(onFinish: @escaping (String?) -> Void) {
      self.onFinish = onFinish
    }

    func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
      let name = CNContactFormatter.string(from: contact, style: .fullName)
      onFinish(name?.isEmpty == false ? name : nil)
    }

    func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
      onFinish(nil)
    }
  }
}
