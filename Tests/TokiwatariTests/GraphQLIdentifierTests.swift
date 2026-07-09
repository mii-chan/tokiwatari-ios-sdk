import Foundation
import Testing
@testable import Tokiwatari

struct GraphQLIdentifierTests {

    private func identifier(_ body: [String: Any]) throws -> String? {
        Tokiwatari.graphQLIdentifier(requestBody: try JSONSerialization.data(withJSONObject: body))
    }

    @Test func namedQueryWithOperationName() throws {
        let result = try identifier([
            "query": "query GetUser($id: ID!) { user(id: $id) { name } }",
            "operationName": "GetUser",
            "variables": ["id": "42"],
        ])
        #expect(result == "GraphQL:Query:GetUser")
    }

    @Test func namedMutationWithoutOperationName() throws {
        let result = try identifier([
            "query": "mutation RemoveItem($id: ID!) { removeItem(id: $id) { ok } }"
        ])
        #expect(result == "GraphQL:Mutation:RemoveItem")
    }

    @Test func operationNameSelectsAmongMultipleDefinitions() throws {
        let document = """
        query ListTeas { teas { id } }
        mutation AddFavorite($id: ID!) { addFavorite(id: $id) { ok } }
        """
        let result = try identifier(["query": document, "operationName": "AddFavorite"])
        #expect(result == "GraphQL:Mutation:AddFavorite")
    }

    @Test func anonymousShorthandIsAQuery() throws {
        #expect(try identifier(["query": "{ teas { id } }"]) == "GraphQL:Query")
    }

    @Test func anonymousMutation() throws {
        #expect(try identifier(["query": "mutation { addFavorite { ok } }"]) == "GraphQL:Mutation")
    }

    @Test func namedSubscription() throws {
        let result = try identifier(["query": "subscription OnTeaAdded { teaAdded { id } }"])
        #expect(result == "GraphQL:Subscription:OnTeaAdded")
    }

    @Test func nonGraphQLBodiesReturnNil() throws {
        #expect(try identifier(["tea_id": 42]) == nil)
        #expect(Tokiwatari.graphQLIdentifier(requestBody: Data("plain text".utf8)) == nil)
        #expect(Tokiwatari.graphQLIdentifier(requestBody: Data("[1,2]".utf8)) == nil)
        #expect(Tokiwatari.graphQLIdentifier(requestBody: nil) == nil)
    }
}
