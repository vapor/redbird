import Vapor
import Foundation

// MARK: RedisCacheCoder

/// An encoder whose output is convertible to a `RESPValue` for storage in Redis.
/// Directly based on `Combine.TopLevelEncoder` but can't extend it because Combine isn't available on Linux.
public protocol RedisCacheEncoder {
    associatedtype Output: RESPValueConvertible
    func encode<T>(_ value: T) throws -> Self.Output where T: Encodable
}

/// A decoder whose input is convertible from a `RESPValue` loaded from Redis.
/// Directly based on `Combine.TopLevelDecoder` but can't extend it because Combine isn't available on Linux.
public protocol RedisCacheDecoder {
    associatedtype Input: RESPValueConvertible
    func decode<T>(_ type: T.Type, from: Self.Input) throws -> T where T: Decodable
}

// Mark Foundation's coders as valid cache coders.
extension JSONEncoder: RedisCacheEncoder { public typealias Output = Data }
extension JSONDecoder: RedisCacheDecoder { public typealias Input = Data }
extension PropertyListEncoder: RedisCacheEncoder { public typealias Output = Data }
extension PropertyListDecoder: RedisCacheDecoder { public typealias Input = Data }

// MARK: - Specific cache instances

extension Application.Caches {
    /// A cache configured for the default Redis ID and the default coders.
    public var redis: Cache {
        self.redis(.default)
    }
    
    /// A cache configured for a given Redis ID and the default coders.
    public func redis(_ id: RedisID) -> Cache {
        self.redis(id, encoder: JSONEncoder(), decoder: JSONDecoder())
    }

    /// A cache configured for a given Redis ID and using the provided encoder and decoder.
    public func redis<E: RedisCacheEncoder, D: RedisCacheDecoder>(_ id: RedisID  = .default, encoder: E, decoder: D) -> Cache {
        RedisCache(encoder: encoder, decoder: decoder, client: self.application.redis(id))
    }
}

// MARK: - Cache instance providers

extension Application.Caches.Provider {
    /// Configures the application cache to use the default Redis ID and coders.
    public static var redis: Self {
        self.redis(.default)
    }

    /// Configures the application cache to use the given Redis ID and the default coders.
    public static func redis(_ id: RedisID) -> Self {
        self.redis(id, encoder: JSONEncoder(), decoder: JSONDecoder())
    }
    
    /// Configures the application cache to use the given Redis ID and the provided encoder and decoder.
    public static func redis<E: RedisCacheEncoder, D: RedisCacheDecoder>(_ id: RedisID  = .default, encoder: E, decoder: D) -> Self {
        .init { $0.caches.use { $0.caches.redis(id, encoder: encoder, decoder: decoder) } }
    }
}

// MARK: - Redis cache driver

/// `Cache` driver for storing cache data in Redis, using a provided encoder and decoder to serialize and deserialize values respectively.
private struct RedisCache<CacheEncoder: RedisCacheEncoder, CacheDecoder: RedisCacheDecoder>: Cache {
    let encoder: CacheEncoder
    let decoder: CacheDecoder
    let client: RedisClient
    
    func get<T: Decodable>(_ key: String, as type: T.Type) -> EventLoopFuture<T?> {
        self.client.get(RedisKey(key), as: CacheDecoder.Input.self).optionalFlatMapThrowing { try self.decoder.decode(T.self, from: $0) }
    }

    func set<T: Encodable>(_ key: String, to value: T?, expiresIn expirationTime: CacheExpirationTime?) -> EventLoopFuture<Void> {
        guard let value = value else {
            return self.client.delete(RedisKey(key)).transform(to: ())
        }
        
        return self.client.eventLoop
            .tryFuture { try self.encoder.encode(value) }
            .flatMap {
                if let expirationTime = expirationTime {
                    return self.client.send(.setex(RedisKey(key), to: $0, expirationInSeconds: expirationTime.seconds), eventLoop: nil, logger: nil)
                } else {
                    return self.client.set(RedisKey(key), to: $0)
                }
            }
    }
    
    func set<T: Encodable>(_ key: String, to value: T?) -> EventLoopFuture<Void> {
        self.set(key, to: value, expiresIn: nil)
    }

    func `for`(_ request: Request) -> Self {
        .init(encoder: self.encoder, decoder: self.decoder, client: request.redis)
    }
}
