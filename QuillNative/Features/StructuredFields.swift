import SwiftUI
import MapKit
import QuillCore

/// Form sections for the post types that are records rather than prose.
struct StructuredFields: View {
    @Binding var draft: Draft
    let weightUnit: String

    var body: some View {
        switch draft.kind {
        case .event: event
        case .review: review
        case .itinerary: itinerary
        case .weight:
            Section {
                LabeledContent("Weight") {
                    HStack(spacing: 6) {
                        TextField("0", text: field("weight"))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("weight.value")
                        Text(weightUnit).foregroundStyle(.secondary)
                    }
                }
            }
        case .exercise:
            Section {
                TextField("Activity", text: field("activity"))
                number("Minutes", "minutes")
                number("Heart Rate", "heartrate", unit: "bpm")
            }
        default: EmptyView()
        }
    }

    @ViewBuilder private var event: some View {
        Section {
            TextField("Name", text: $draft.title)
            ISODateField(title: "Starts", value: field("start"))
            Toggle("Ends", isOn: Binding(get: { !(draft.fields["end"] ?? "").isEmpty }, set: { isOn in
                withAnimation(.snappy) { draft.fields["end"] = isOn ? ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600)) : "" }
            }))
            if !(draft.fields["end"] ?? "").isEmpty { ISODateField(title: "Ends", value: field("end")) }
        }
        Section {
            TextField("Description", text: $draft.content, axis: .vertical).lineLimit(3...)
            Picker("Format", selection: field("p3k-content-type")) {
                Text("Plain Text").tag("")
                Text("Markdown").tag("text/markdown")
            }
        }
        Section {
            DisclosureGroup("Place") {
                TextField("Name", text: field("place-name"))
                TextField("Street", text: field("place-street-address"))
                TextField("City", text: field("place-locality"))
                TextField("Region", text: field("place-region"))
                TextField("Country", text: field("place-country-name"))
                url("Website", "place-url")
            }
            DisclosureGroup("Conference") {
                TextField("Name", text: field("conference-name"))
                url("Website", "conference-url")
                url("Slides", "slides")
                TextField("Slides Embed", text: field("slides-embed"), axis: .vertical)
                url("Video", "video-link")
                TextField("Video Embed", text: field("video-embed"), axis: .vertical)
            }
        }
    }

    @ViewBuilder private var review: some View {
        Section {
            TextField("Item", text: field("item-name"))
            url("URL", "item-url")
            StarRating(value: field("rating"))
        }
        Section {
            TextField("Summary", text: field("summary"))
            TextField("Review", text: $draft.content, axis: .vertical).lineLimit(4...)
            Toggle("HTML", isOn: $draft.isHTML)
        }
    }

    @ViewBuilder private var itinerary: some View {
        ForEach($draft.legs) { $leg in
            LegEditor(leg: $leg, canRemove: draft.legs.count > 1) {
                withAnimation(.snappy) { draft.legs.removeAll { $0.id == leg.id } }
            }
        }
        Section {
            Button("Add Leg", systemImage: "plus") { withAnimation(.snappy) { draft.legs.append(Leg()) } }
        }
    }

    private func field(_ name: String) -> Binding<String> {
        Binding(get: { draft.fields[name] ?? "" }, set: { draft.fields[name] = $0 })
    }

    private func url(_ title: String, _ name: String) -> some View {
        TextField(title, text: field(name))
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
    }

    private func number(_ title: String, _ name: String, unit: String? = nil) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField("0", text: field(name)).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                if let unit { Text(unit).foregroundStyle(.secondary) }
            }
        }
    }
}

private struct StarRating: View {
    @Binding var value: String
    private var rating: Int { Int(Double(value) ?? 0) }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(1...5, id: \.self) { star in
                Button { withAnimation(.snappy(duration: 0.2)) { value = String(star) } } label: {
                    Image(systemName: star <= rating ? "star.fill" : "star")
                        .font(.title2)
                        .foregroundStyle(star <= rating ? Color.yellow : Color.secondary)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .sensoryFeedback(.selection, trigger: rating)
        .accessibilityElement()
        .accessibilityLabel("Rating")
        .accessibilityValue("\(rating) of 5")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = String(min(5, rating + 1))
            case .decrement: value = String(max(1, rating - 1))
            @unknown default: break
            }
        }
    }
}

private struct LegEditor: View {
    @Binding var leg: Leg
    let canRemove: Bool
    let remove: () -> Void
    @State private var query = ""
    @State private var results: [MKMapItem] = []

    var body: some View {
        Section {
            Picker("Mode", selection: $leg.transitType) {
                Label("Air", systemImage: "airplane").tag("air")
                Label("Train", systemImage: "tram").tag("train")
                Label("Bus", systemImage: "bus").tag("bus")
                Label("Boat", systemImage: "ferry").tag("boat")
                Label("Car", systemImage: "car").tag("car")
                Label("Walk", systemImage: "figure.walk").tag("walk")
            }
            TextField("Operator", text: $leg.operatorName)
            TextField("Number", text: $leg.number)
            TextField("From", text: $leg.origin)
            TextField("To", text: $leg.destination)
            ISODateField(title: "Departs", value: $leg.departure)
            ISODateField(title: "Arrives", value: $leg.arrival)
            DisclosureGroup("Find a Place") {
                TextField("Airport, Station, or City", text: $query)
                    .submitLabel(.search)
                    .onSubmit { Task { await search() } }
                ForEach(Array(results.prefix(5).enumerated()), id: \.offset) { _, item in
                    Menu(item.name ?? "") {
                        Button("From") { leg.origin = item.name ?? "" }
                        Button("To") { leg.destination = item.name ?? "" }
                    }
                }
            }
            if canRemove { Button("Remove Leg", role: .destructive, action: remove) }
        }
    }

    private func search() async {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        let found = (try? await MKLocalSearch(request: request).start().mapItems) ?? []
        withAnimation(.snappy) { results = found }
    }
}
