import Foundation
import Testing
import Domain

@Test func legacyMaterializedStateDecodesWithoutLosingMessages() throws {
    let event = DomainEvent(author: UUID(), sequence: 1, lamport: 1, createdAt: Date(), payload: .message(text: "already saved"))
    var legacy = SharedState(); try legacy.apply(event, cycleOwner: nil)
    var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as! [String: Any]
    object.removeValue(forKey: "journalStorage")
    let restored = try JSONDecoder().decode(SharedState.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(restored.messages == legacy.messages)
    #expect(restored.journal.capsules.isEmpty)
}

@Test func checklistConcurrentEditsAndDeletionConverge() throws {
    let a = UUID(), b = UUID(), id = UUID(), now = Date()
    let create = DomainEvent(objectID: id, author: a, sequence: 1, lamport: 1, createdAt: now,
        payload: .journal(.checklist(ChecklistContent(text: "早餐", category: .eat))))
    let complete = DomainEvent(objectID: id, author: b, sequence: 1, lamport: 2, createdAt: now,
        payload: .journal(.checklist(ChecklistContent(text: "早餐", category: .eat, completed: true))))
    let delete = DomainEvent(objectID: id, author: a, sequence: 2, lamport: 3, createdAt: now,
        payload: .journal(.checklist(ChecklistContent(text: "早餐", category: .eat, deleted: true))))
    var left = SharedState(), right = SharedState()
    for e in [create, complete, delete] { try left.apply(e, cycleOwner: nil) }
    for e in [delete, complete, create, complete] { try right.apply(e, cycleOwner: nil) }
    #expect(left == right)
    #expect(left.journal.checklist[id]?.value.deleted == true)
}

@Test func capsuleTimeBoundaryCancellationAndAuthorIsolation() throws {
    let owner = UUID(), peer = UUID(), id = UUID(), now = Date(timeIntervalSince1970: 1_000)
    let seal = DomainEvent(objectID: id, author: owner, sequence: 1, lamport: 1, createdAt: now,
        payload: .journal(.sealCapsule(CapsuleContent(title: "未来", text: "给你", opensAt: now.addingTimeInterval(100)))))
    let wrong = DomainEvent(objectID: id, author: peer, sequence: 1, lamport: 2, createdAt: now.addingTimeInterval(10), payload: .journal(.cancelCapsule))
    var state = SharedState()
    try state.apply(wrong, cycleOwner: nil); try state.apply(seal, cycleOwner: nil)
    let capsule = try #require(state.journal.capsules[id])
    #expect(!state.journal.isCancelled(capsule))
    #expect(!state.journal.canOpen(capsule, now: now.addingTimeInterval(99)))
    #expect(state.journal.canOpen(capsule, now: now.addingTimeInterval(100)))
    #expect(!state.journal.canOpen(capsule, now: now)) // a clock adjustment never leaves cached body visible
    let cancel = DomainEvent(objectID: id, author: owner, sequence: 2, lamport: 3, createdAt: now.addingTimeInterval(20), payload: .journal(.cancelCapsule))
    var reversed = SharedState()
    for e in [cancel, wrong, seal] { try reversed.apply(e, cycleOwner: nil) }
    try state.apply(cancel, cycleOwner: nil)
    #expect(state == reversed)
    #expect(!state.journal.canOpen(capsule, now: now.addingTimeInterval(101)))
}

@Test func capsuleCannotBeRewrittenOrCreatedAlreadyExpired() throws {
    let owner = UUID(), id = UUID(), now = Date()
    let first = DomainEvent(objectID: id, author: owner, sequence: 1, lamport: 1, createdAt: now,
        payload: .journal(.sealCapsule(CapsuleContent(title: "未来", text: "第一份", opensAt: now.addingTimeInterval(100)))))
    let changed = DomainEvent(objectID: id, author: owner, sequence: 2, lamport: 2, createdAt: now,
        payload: .journal(.sealCapsule(CapsuleContent(title: "未来", text: "被改写", opensAt: now.addingTimeInterval(100)))))
    var state = SharedState(); try state.apply(first, cycleOwner: nil)
    #expect(throws: SpaceError.conflict) { try state.apply(changed, cycleOwner: nil) }
    let past = DomainEvent(author: owner, sequence: 3, lamport: 3, createdAt: now,
        payload: .journal(.sealCapsule(CapsuleContent(title: "过去", text: "不能封存", opensAt: now))))
    #expect(throws: SpaceError.invalidInput) { try past.validate(cycleOwner: nil) }
}

@Test func sharedMemorySourceIsStableAcrossConcurrentSaves() throws {
    let a = UUID(), b = UUID(), source = UUID(), now = Date()
    let value = MemoryContent(title: "早餐", text: "来自愿望", date: now, sourceID: source)
    let first = DomainEvent(objectID: source, author: a, sequence: 1, lamport: 1, createdAt: now, payload: .journal(.memory(value)))
    let second = DomainEvent(objectID: source, author: b, sequence: 1, lamport: 1, createdAt: now, payload: .journal(.memory(value)))
    var left = SharedState(), right = SharedState()
    for e in [first, second] { try left.apply(e, cycleOwner: nil) }
    for e in [second, first] { try right.apply(e, cycleOwner: nil) }
    #expect(left == right); #expect(left.journal.memories.count == 1)
}

@Test func photoMemoryReferenceIsStableAndLegacyTextMemoryStillDecodes() throws {
    let photoID = UUID(), now = Date()
    let photo = MemoryContent(title: "一起留下的照片", text: "", date: now,
                              sourceID: photoID, mediaID: photoID)
    try JournalOperation.memory(photo).validate(createdAt: now)
    #expect(try JSONDecoder().decode(MemoryContent.self, from: JSONEncoder().encode(photo)).mediaID == photoID)
    let invalid = MemoryContent(title: "错配", text: "", date: now, sourceID: UUID(), mediaID: photoID)
    #expect(throws: SpaceError.invalidInput) {
        try JournalOperation.memory(invalid).validate(createdAt: now)
    }
    var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(photo)) as! [String: Any]
    legacy.removeValue(forKey: "mediaID")
    #expect(try JSONDecoder().decode(MemoryContent.self,
                                    from: JSONSerialization.data(withJSONObject: legacy)).mediaID == nil)
}
