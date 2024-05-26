import Redis
import Vapor
import XCTest
import XCTRedis
import XCTVapor

private extension RedisID {
    static let one: RedisID = "one"
    static let two: RedisID = "two"
}

class XCTRedisUsage: XCTestCase {
    func test_usage_redis_fake_client() throws {
        let app = Application()
        let client = ArrayTestRedisClient()

        defer { app.shutdown() }

        client.prepare(with: .success(.bulkString(.init(string: "redis_version_one"))))
        client.prepare(with: .success(.bulkString(.init(string: "redis_version_two"))))

        app.redis(.one).use(.stub(client: client))
        app.redis(.two).use(.stub(client: client))

        try app.boot()

        let info1 = try app.redis(.one).send(command: "INFO").wait()
        XCTAssertContains(info1.string, "redis_version_one")

        let info2 = try app.redis(.two).send(command: "INFO").wait()
        XCTAssertContains(info2.string, "redis_version_two")
    }

    func test_usage_of_pubSub_fake_client() throws {
        let expectedChannel = RedisChannelName("common_channel")
        let expectedMessage = "Hello from redis pubSub"

        let app = Application()
        let client = ArrayTestRedisClient()

        defer { app.shutdown() }

        app.redis.use(.stub(client: client))

        try app.boot()

        client.prepare(error: nil) // SUB
        client.prepare(with: .success(.integer(1))) // PUB
        client.prepare(error: nil) // UNSUB

        try app
            .redis
            .subscribe(
                to: [expectedChannel],
                messageReceiver: { publisher, message in
                    XCTAssertEqual(publisher, expectedChannel)
                    XCTAssertEqual(message.string, expectedMessage)
                }, onSubscribe: { channel, amount in
                    XCTAssertEqual(channel, expectedChannel.rawValue)
                    XCTAssertEqual(amount, 1)
                }, onUnsubscribe: { channel, amount in
                    XCTAssertEqual(channel, expectedChannel.rawValue)
                    XCTAssertEqual(amount, 0)
                }
            ).wait()

        let listeners = try app.redis.publish(expectedMessage, to: expectedChannel).wait()
        XCTAssertEqual(listeners, 1)

        try app.redis.unsubscribe(from: [expectedChannel]).wait()
    }
}
