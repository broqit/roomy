import Foundation

if CommandLineInterface.handles(CommandLine.arguments) {
    Task {
        let status = await CommandLineInterface.run(CommandLine.arguments)
        exit(status)
    }
    dispatchMain()
} else {
    CleanMacApp.main()
}
