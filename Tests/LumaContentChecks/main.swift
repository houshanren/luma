import TestSupport

runSourceChecks()
await runTransportChecks()
await runPlaybackChecks()
await runCatalogPlaybackChecks()
runIPTVChecks()

CheckRecorder.shared.finish()
