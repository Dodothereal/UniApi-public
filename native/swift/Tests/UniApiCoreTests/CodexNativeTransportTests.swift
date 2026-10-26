import Foundation
import XCTest
@testable import UniApiCore

final class CodexNativeTransportTests: XCTestCase {
    private func assertDirect(_ configuration: URLSessionConfiguration, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(configuration.connectionProxyDictionary as? [String: Int], [
            "HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0,
            "ProxyAutoConfigEnable": 0, "ProxyAutoDiscoveryEnable": 0
        ], file: file, line: line)
    }

    func testProxyBypassIsAnExplicitTrailingInitializerOption() throws {
        let url = try XCTUnwrap(URL(string: "https://upstream.invalid/v1/responses"))
        let legacy = ShimHTTPRequest(url: url, method: "GET", headers: ["Accept": "application/json"], body: Data([1]), timeout: 12.5)
        XCTAssertFalse(legacy.bypassSystemProxy)
        let direct = ShimHTTPRequest(url: url, method: legacy.method, headers: legacy.headers, body: legacy.body, timeout: legacy.timeout, bypassSystemProxy: true)
        XCTAssertTrue(direct.bypassSystemProxy)
        XCTAssertEqual(direct.url, legacy.url); XCTAssertEqual(direct.method, legacy.method)
        XCTAssertEqual(direct.headers, legacy.headers); XCTAssertEqual(direct.body, legacy.body); XCTAssertEqual(direct.timeout, legacy.timeout)
    }

    func testExplicitDirectPolicyDisablesAllSystemProxyMechanismsForRemoteHTTPAndHTTPS() throws {
        for scheme in ["http", "https"] {
            let url = try XCTUnwrap(URL(string: scheme + "://upstream.invalid/v1/responses"))
            let request = ShimHTTPRequest(url: url, bypassSystemProxy: true)
            assertDirect(ShimURLSessionTransport.configuration(for: request))
        }
    }

    func testExistingLoopbackAddressesRemainDirectWithoutOptingIn() throws {
        for scheme in ["http", "https"] {
            for host in ["127.0.0.1", "localhost", "[::1]"] {
                let url = try XCTUnwrap(URL(string: scheme + "://" + host + ":8823/healthz"))
                let request = ShimHTTPRequest(url: url)
                XCTAssertFalse(request.bypassSystemProxy)
                assertDirect(ShimURLSessionTransport.configuration(for: request))
            }
        }
    }

    func testDefaultRemotePolicyLeavesSystemProxySelectionUnchanged() throws {
        for endpoint in ["https://upstream.invalid/v1/responses", "http://192.0.2.1/", "http://[2001:db8::1]/",
                         "http://127.0.0.1.upstream.invalid/", "http://localhost.upstream.invalid/"] {
            let request = ShimHTTPRequest(url: try XCTUnwrap(URL(string: endpoint)))
            XCTAssertFalse(request.bypassSystemProxy)
            XCTAssertNil(ShimURLSessionTransport.configuration(for: request).connectionProxyDictionary, endpoint)
        }
    }

    func testDirectDefaultAndLoopbackPoliciesKeepSessionStorageIsolatedAndPreserveTimeouts() throws {
        for endpoint in ["https://upstream.invalid/v1/responses", "http://127.0.0.1:8823/healthz"] {
            let url = try XCTUnwrap(URL(string: endpoint))
            for bypass in [false, true] {
                let request = ShimHTTPRequest(url: url, timeout: 12.5, bypassSystemProxy: bypass)
                let configuration = ShimURLSessionTransport.configuration(for: request)
                XCTAssertFalse(configuration.httpShouldSetCookies)
                XCTAssertNil(configuration.httpCookieStorage)
                XCTAssertNil(configuration.urlCredentialStorage)
                XCTAssertNil(configuration.urlCache)
                XCTAssertNil(configuration.identifier)
                XCTAssertEqual(configuration.timeoutIntervalForRequest, request.timeout)
                XCTAssertEqual(configuration.timeoutIntervalForResource, request.timeout)
            }
        }
    }

    func testEachRequestGetsAnIndependentConfigurationWithoutLeakingDirectPolicy() throws {
        let url = try XCTUnwrap(URL(string: "https://upstream.invalid/v1/responses"))
        let direct = ShimURLSessionTransport.configuration(for: ShimHTTPRequest(url: url, bypassSystemProxy: true))
        assertDirect(direct)
        direct.httpShouldSetCookies = true
        direct.timeoutIntervalForRequest = 1
        direct.timeoutIntervalForResource = 2
        direct.connectionProxyDictionary = ["HTTPEnable": 1, "HTTPProxy": "proxy.invalid", "HTTPPort": 8080]

        let request = ShimHTTPRequest(url: url)
        let inherited = ShimURLSessionTransport.configuration(for: request)
        XCTAssertFalse(direct === inherited)
        XCTAssertNil(inherited.connectionProxyDictionary)
        XCTAssertFalse(inherited.httpShouldSetCookies)
        XCTAssertEqual(inherited.timeoutIntervalForRequest, 600)
        XCTAssertEqual(inherited.timeoutIntervalForResource, 600)
        assertDirect(ShimURLSessionTransport.configuration(for: ShimHTTPRequest(url: url, bypassSystemProxy: true)))
    }
}
