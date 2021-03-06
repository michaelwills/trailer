
import UIKit

final class AboutTrailerViewController: UIViewController {
	@IBOutlet weak var versionNumber: UILabel!
	@IBOutlet weak var licenseText: UITextView!

	override func viewDidLoad() {
		super.viewDidLoad()
		versionNumber.text = versionString()
		licenseText.textContainerInset = UIEdgeInsetsMake(0, 10, 10, 10)
	}

	override func viewDidAppear(animated: Bool) {
		super.viewDidAppear(animated)
		licenseText.contentOffset = CGPointZero
	}

	@IBAction func linkSelected() {
		UIApplication.sharedApplication().openURL(NSURL(string: "https://github.com/ptsochantaris/trailer")!)
	}

	@IBAction func doneSelected() {
		if app.preferencesDirty { app.startRefresh() }
		dismissViewControllerAnimated(true, completion: nil)
	}
}
