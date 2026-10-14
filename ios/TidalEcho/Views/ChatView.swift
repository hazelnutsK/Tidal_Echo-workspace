import AudioToolbox
@preconcurrency import AVFoundation
import KaomojiDrawerKit
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ChatView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var nativeCalls = NativeCallCoordinator.shared
    @State private var showingSettings = false
    @State private var showingSpaces = false
    @State private var showingVoiceCall = false
    @State private var isPresentingVoiceCall = false
    @State private var showingTerminal = false
    @State private var showingSearch = false
    @State private var showingSessions = false
    @State private var askSheetContext: AskSheetContext?
    @State private var seenAskMessageIDs = Set<Int>()
    @State private var didPrimeAskAutopresentation = false
    @State private var peekSheetContext: PeekSheetContext?
    @State private var seenPeekMessageIDs = Set<Int>()
    @State private var didPrimePeekAutopresentation = false
    @State private var editingMessage: ChatMessage?
    @State private var pendingRegeneration: ChatMessage?
    @State private var pendingHide: ChatMessage?
    /// nil＝没在多选；否则是选中的消息 id。
    @State private var selectedMessageIDs: Set<Int>?
    @State private var isWorkingOnSelection = false
    @State private var shareCard: ShareCardImage?
    @State private var didPositionInitialHistory = false
    @State private var canTriggerOlderHistory = false
    @State private var isPrependingHistory = false
    @State private var composerHeight: CGFloat = 126
    @State private var isAtBottom = true
    @State private var newMessageCount = 0
    @State private var observedMessageCount = 0
    @State private var chatScrollView: UIScrollView?

    private var palette: EchoPalette { model.theme.palette }
    private var isNest: Bool { model.theme == .nest }
    private var usesIMessageLayout: Bool { model.chatLayoutStyle == .imessage }
    private var usesUpperTailAvatarLayout: Bool {
        guard model.showsAIAvatar,
              model.showsHumanAvatar,
              model.bubbleShapeStyle == .upperTail else { return false }
        return model.bubbleStyle == .classic || model.bubbleStyle == .frosted
    }
    private var historyEndsWithAIThinkingHeader: Bool {
        for row in chatRows.reversed() {
            guard row.message.author == .ai else { return false }
            if row.message.kind == "thinking" {
                if row.showsAvatarHeader { return true }
                continue
            }
            if row.message.kind != "act" { return false }
        }
        return false
    }

    var body: some View {
        ZStack {
            palette.background.ignoresSafeArea()
            if let background = model.visibleBackgroundImage {
                GeometryReader { geometry in
                    Image(uiImage: background)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .scaleEffect(1 + model.backgroundBlur / 260)
                        .blur(radius: model.backgroundBlur)
                        .clipped()
                        .opacity(model.backgroundOpacity)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }

            GeometryReader { viewport in
                ZStack(alignment: .top) {
                    let metrics = IMessageLayoutMetrics(viewportWidth: viewport.size.width)
                    messageList(topInset: usesIMessageLayout
                        ? viewport.safeAreaInsets.top + metrics.headerHeight
                        : (isNest ? nestTopInset : 76))
                        .zIndex(0)
                    topFog(safeAreaTop: viewport.safeAreaInsets.top,
                           headerHeight: usesIMessageLayout ? metrics.headerHeight : 55)
                        .zIndex(1)
                    if usesIMessageLayout {
                        IMessageChatHeader(
                            model: model, metrics: metrics,
                            onSettings: { showingSettings = true },
                            onTerminal: { showingTerminal = true },
                            onSpaces: { showingSpaces = true },
                            onSessions: { showingSessions = true }
                        )
                        .zIndex(2)
                    } else {
                        topBar.zIndex(2)
                    }

                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        ComposerView(
                            model: model,
                            viewportWidth: viewport.size.width,
                            onShowSessions: { showingSessions = true }
                        )
                            .background {
                                GeometryReader { geometry in
                                    Color.clear.preference(
                                        key: ComposerHeightPreferenceKey.self,
                                        value: geometry.size.height
                                    )
                                }
                            }
                            // Kept alive under the bar so an unsent draft survives multi-select.
                            .opacity(selectedMessageIDs == nil ? 1 : 0)
                            .allowsHitTesting(selectedMessageIDs == nil)
                            .overlay(alignment: .bottom) {
                                if let selected = selectedMessageIDs {
                                    MessageSelectionBar(
                                        count: selected.count,
                                        allStarred: !selected.isEmpty && selectedMessages.allSatisfy { $0.meta.starred != nil },
                                        isWorking: isWorkingOnSelection,
                                        palette: palette,
                                        onStar: starSelection,
                                        onShare: shareSelection,
                                        onCancel: {
                                            withAnimation(.easeOut(duration: 0.18)) { selectedMessageIDs = nil }
                                        }
                                    )
                                    .transition(.move(edge: .bottom).combined(with: .opacity))
                                }
                            }
                    }
                    .zIndex(3)
                }
            }

            if model.showsClawdPet {
                ClawdPetOverlay(model: model, bottomInset: composerHeight + 4)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    .zIndex(10)
            }

            if let invite = nativeCalls.ringingInvite,
               nativeCalls.shouldPlayInAppRingtone {
                NativeIncomingCallOverlay(
                    model: model,
                    invite: invite,
                    onAccept: { presentVoiceCallDirectly() },
                    onDecline: { nativeCalls.declineRingingCall() }
                )
                .transition(.opacity)
                .zIndex(20)
            }
        }
        .environment(\.processTitleColor, model.customProcessTitleColor)
        .environment(\.timestampColor, model.customTimestampColor)
        .environment(\.processTitleFont, model.processTitleFont)
        .environment(\.showsProcessDisclosure, model.showsProcessDisclosure)
        .environment(\.bubblePaddingOffset, model.bubblePaddingOffset)
        .sheet(isPresented: $showingSettings) {
            SettingsView(
                model: model,
                onSearch: { showingSearch = true },
                onCall: { showingVoiceCall = true }
            )
                .presentationDetents([.medium, .large])
        }
        .sheet(item: $shareCard) { card in
            MessageShareSheet(card: card, palette: palette)
        }
        .sheet(isPresented: $showingSearch) {
            MessageSearchView(model: model)
        }
        .sheet(item: $askSheetContext) { context in
            MessageAskSheet(model: model, context: context)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.hidden)
                .presentationCornerRadius(28)
        }
        .sheet(item: $peekSheetContext) { context in
            MessagePeekSheet(model: model, context: context)
                .presentationDetents([.height(330)])
                .presentationDragIndicator(.hidden)
                .presentationCornerRadius(28)
        }
        .sheet(isPresented: $showingSessions) {
            SessionManagerView(model: model)
        }
        .sheet(item: $editingMessage) { message in
            EditMessageView(model: model, message: message)
        }
        .fullScreenCover(isPresented: $showingSpaces) {
            SpacesView(model: model)
        }
        .fullScreenCover(isPresented: $showingVoiceCall) {
            VoiceCallView(model: model)
        }
        .fullScreenCover(isPresented: $showingTerminal) {
            NavigationStack {
                TerminalView(model: model)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button { showingTerminal = false } label: {
                                Image(systemName: "chevron.down")
                            }
                            .accessibilityLabel("关闭终端")
                        }
                    }
            }
        }
        .onAppear {
            openAcceptedCallIfNeeded()
            primeAskAutopresentationIfNeeded()
            primePeekAutopresentationIfNeeded()
            observedMessageCount = model.messages.count
        }
        .onPreferenceChange(ComposerHeightPreferenceKey.self) { height in
            if height > 0 { composerHeight = height }
        }
        .onChange(of: nativeCalls.acceptedInvite?.id) { _ in openAcceptedCallIfNeeded() }
        .onChange(of: model.isLoadingHistory) { loading in
            if loading {
                didPrimeAskAutopresentation = false
                didPrimePeekAutopresentation = false
            } else {
                primeAskAutopresentationIfNeeded()
                primePeekAutopresentationIfNeeded()
            }
        }
        .onChange(of: newestUnansweredAskID) { _ in
            presentNewestAskIfNeeded()
        }
        .onChange(of: newestPendingPeekID) { _ in
            presentNewestPeekIfNeeded()
        }
        .confirmationDialog(
            "重新生成这条回复？",
            isPresented: Binding(
                get: { pendingRegeneration != nil },
                set: { if !$0 { pendingRegeneration = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("重新生成") {
                guard let message = pendingRegeneration else { return }
                pendingRegeneration = nil
                Task {
                    do { try await model.regenerateMessage(id: message.id) }
                    catch { model.errorMessage = error.localizedDescription }
                }
            }
            Button("取消", role: .cancel) { pendingRegeneration = nil }
        }
        .confirmationDialog(
            "只在这台 iPhone 上隐藏这条消息？",
            isPresented: Binding(
                get: { pendingHide != nil },
                set: { if !$0 { pendingHide = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("隐藏", role: .destructive) {
                guard let message = pendingHide else { return }
                pendingHide = nil
                model.hideMessageLocally(id: message.id)
            }
            Button("取消", role: .cancel) { pendingHide = nil }
        } message: {
            Text("不会删除服务器或对方那边的记录。")
        }
    }

    private var topBar: some View {
        topBarContent
            .padding(.horizontal, 16)
            .padding(.top, 9)
            .padding(.bottom, 8)
    }

    @ViewBuilder
    private var topBarContent: some View {
        HStack(spacing: 10) {
            if isNest {
                Button { showingSettings = true } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(palette.text)
                        .frame(width: 38, height: 38)
                        .background { headerGlass(shape: Circle()) }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)

            } else {
                headerButton(icon: "slider.horizontal.3", size: 17) { showingSettings = true }
            }

            Spacer(minLength: 6)

            if model.isLoadingHistory {
                ProgressView()
                    .controlSize(.small)
                    .tint(palette.accent)
            }

            if isNest {
                HStack(spacing: 0) {
                    nestHeaderButton(icon: "terminal", size: 15) { showingTerminal = true }
                    Rectangle()
                        .fill(palette.hairline)
                        .frame(width: 0.6, height: 18)
                    nestHeaderButton(icon: "square.grid.2x2", size: 16) { showingSpaces = true }
                }
                .padding(.horizontal, 3)
                .background { headerGlass(shape: Capsule()) }
            } else {
                HStack(spacing: 14) {
                    headerButton(icon: "terminal", size: 15) { showingTerminal = true }
                    headerButton(icon: "square.grid.2x2", size: 16) { showingSpaces = true }
                }
            }
        }
    }

    private func nestHeaderButton(icon: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(palette.text)
                .frame(width: 37, height: 38)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The list deliberately ignores the container's top safe area so chat can
    /// run under the status bar — which also leaves the system nothing to hang
    /// its edge effect on. Hand the device inset back in explicitly, plus the
    /// height of the floating header, so the fade covers both.
    private var nestTopInset: CGFloat {
        let device = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?
            .keyWindow?
            .safeAreaInsets.top ?? 59
        return device + 55
    }

    private func topFog(safeAreaTop: CGFloat, headerHeight: CGFloat) -> some View {
        ZStack {
            // Keep the strongest blur near the status bar and only a short,
            // gentle fade below the header, so a small scroll stays legible.
            VariableBackdropBlur(
                radius: isNest ? 5 : 7,
                mask: .blurredTopClearBottom,
                fadeFrom: 0,
                fadeTo: 1,
                falloff: .gentle
            )

            Rectangle()
                .fill(topFogTint)
                .mask(
                    LinearGradient(
                        stops: topFogStops,
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
        .frame(height: safeAreaTop + headerHeight + 12)
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func headerGlass<S: InsettableShape>(shape: S) -> some View {
        ZStack {
            VariableBackdropBlur(radius: 18, mask: .solid)
            shape.fill(headerGlassTint)
        }
        .clipShape(shape)
        .overlay(shape.stroke(headerGlassRing, lineWidth: 0.65))
        .shadow(color: headerShadowColor, radius: model.theme == .paper ? 10 : 11, y: 3.5)
    }

    private func headerButton(icon: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(palette.text)
                .frame(width: 32, height: 32)
                .background { headerGlass(shape: Circle()) }
        }
        .buttonStyle(.plain)
    }

    private var headerGlassTint: Color {
        switch model.theme {
        case .mist: return Color(hex: 0xF7FAFC).opacity(0.52)
        case .paper: return Color(hex: 0xF0EEE6).opacity(0.62)
        case .harbor: return Color.black.opacity(0.32)
        case .nest: return Color.white.opacity(0.52)
        }
    }

    private var headerGlassRing: Color {
        switch model.theme {
        case .mist: return Color.white.opacity(0.48)
        case .paper: return Color.white.opacity(0.48)
        case .harbor: return Color.white.opacity(0.12)
        case .nest: return Color.white.opacity(0.78)
        }
    }

    private var headerShadowColor: Color {
        switch model.theme {
        case .mist: return Color.black.opacity(0.10)
        case .paper: return Color(hex: 0x8C7466).opacity(0.16)
        case .harbor: return Color.black.opacity(0.18)
        case .nest: return Color.black.opacity(0.075)
        }
    }

    private var topFogTint: Color {
        switch model.theme {
        case .mist: return Color(hex: 0xECF1F6).opacity(0.12)
        case .paper: return Color(hex: 0xFAFAF8).opacity(0.36)
        case .harbor: return Color.black.opacity(0.19)
        case .nest: return Color(hex: 0xF7F7F5).opacity(0.23)
        }
    }

    private var topFogStops: [Gradient.Stop] {
        // Let the glyph lose focus before the tint washes it away. Match the
        // blur's eased entrance instead of adding another visible fade edge.
        (0...24).map { index in
            let location = CGFloat(index) / 24
            let progress = 1 - location
            let smooth = progress * progress * (3 - 2 * progress)
            let strength = Double(smooth * smooth) * (isNest ? 0.60 : 1)
            return .init(color: .black.opacity(strength), location: location)
        }
    }

    private func messageList(topInset: CGFloat) -> some View {
        ScrollViewReader { proxy in
            GeometryReader { viewport in
                ScrollView {
                    LazyVStack(spacing: isNest ? 13 : 9) {
                    if canTriggerOlderHistory && model.canLoadOlderHistory {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("载入更早的记录…")
                        }
                        .font(.caption)
                        .foregroundStyle(palette.secondaryText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                    }

                    if model.messages.isEmpty && !model.isLoadingHistory {
                        VStack(spacing: 10) {
                            Image(systemName: "water.waves")
                                .font(.system(size: 28, weight: .light))
                            Text("这里只有你和\(model.peerDisplayName)。\n说点什么吧。")
                                .multilineTextAlignment(.center)
                        }
                        .foregroundStyle(palette.secondaryText)
                        .padding(.top, 120)
                    }

                    ForEach(chatRows) { row in
                        let message = row.message
                        MessageRow(
                            message: message,
                            palette: palette,
                            chatFont: message.author == .human ? model.resolvedHumanChatFont : model.chatFont,
                            fontScale: message.author == .human ? model.humanFontScale : model.fontScale,
                            showsAIAvatar: model.showsAIAvatar,
                            showsHumanAvatar: model.showsHumanAvatar,
                            aiAvatarImage: model.aiAvatarImage,
                            humanAvatarImage: model.humanAvatarImage,
                            showsAIBubble: model.showsAIBubble,
                            aiBubbleColor: model.resolvedAIBubbleColor(default: palette.aiBubble),
                            humanBubbleColor: model.resolvedHumanBubbleColor(default: palette.humanBubble),
                            aiBubbleTextColor: model.resolvedAIBubbleTextColor(default: palette.text),
                            humanBubbleTextColor: model.resolvedHumanBubbleTextColor(default: palette.text),
                            bubbleOpacity: message.author == .human
                                ? model.humanBubbleOpacity
                                : model.aiBubbleOpacity,
                            bubbleRadius: model.bubbleRadius,
                            bubbleWidthScale: model.bubbleWidthScale,
                            bubbleBorderWidth: model.bubbleBorderWidth,
                            bubbleStyle: model.bubbleStyle,
                            bubbleShapeStyle: model.bubbleShapeStyle,
                            liquidGlass: model.liquidGlassSettings,
                            chatWeight: model.chatWeight,
                            peerName: model.peerDisplayName,
                            showsTimestamp: row.showsTimestamp,
                            apiUsageText: model.apiUsageText(for: message),
                            isGroupStart: row.isGroupStart,
                            showsAvatarHeader: row.showsAvatarHeader,
                            isTail: model.chatMode == .short && model.bubbleStyle == .classic
                                ? false
                                : row.isTail,
                            isGroupedWithPrevious: !row.isGroupStart,
                            isPaper: model.theme == .paper,
                            isMist: model.theme == .mist,
                            isNest: model.theme == .nest,
                            isNestGroupTail: row.isTail,
                            showsNestDisclaimer: message.id == latestAIReplyID
                                && !model.isTyping
                                && model.streamingThinking.isEmpty
                                && model.streamingReply.isEmpty,
                            isIncomingCallActive: nativeCalls.ringingInvite?.id == message.id
                                || nativeCalls.acceptedInvite?.id == message.id,
                            onBeginSelection: Self.isSelectable(message) ? {
                                UIApplication.shared.sendAction(
                                    #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
                                )
                                withAnimation(.easeOut(duration: 0.18)) { selectedMessageIDs = [message.id] }
                            } : nil,
                            onToggleStar: {
                                Task {
                                    do {
                                        try await model.setStar(
                                            messageID: message.id,
                                            on: message.meta.starred == nil
                                        )
                                    } catch {
                                        model.errorMessage = error.localizedDescription
                                    }
                                }
                            },
                            onSpeak: {
                                Task { await model.speakMessage(message) }
                            },
                            onCopy: {
                                UIPasteboard.general.string = message.text
                            },
                            onEdit: {
                                editingMessage = message
                            },
                            onRegenerate: {
                                pendingRegeneration = message
                            },
                            onHide: {
                                pendingHide = message
                            },
                            onReact: { emoji in
                                Task {
                                    do { try await model.reactToMessage(messageID: message.id, emoji: emoji) }
                                    catch { model.errorMessage = error.localizedDescription }
                                }
                            },
                            onTranslateThinking: {
                                try await model.translateThinking(messageID: message.id)
                            },
                            onCompleteTimer: {
                                Task {
                                    do { try await model.completeTimer(messageID: message.id) }
                                    catch { model.errorMessage = error.localizedDescription }
                                }
                            },
                            onOpenAsk: {
                                guard let ask = message.meta.ask else { return }
                                askSheetContext = AskSheetContext(messageID: message.id, initialAsk: ask)
                            },
                            peekNeedsManualPicker: model.peekManualPickerID == message.id,
                            onAcceptPeek: {
                                do { try await model.acceptPeek(messageID: message.id) }
                                catch { model.errorMessage = error.localizedDescription }
                            },
                            onDeclinePeek: {
                                do { try await model.declinePeek(messageID: message.id) }
                                catch { model.errorMessage = error.localizedDescription }
                            },
                            onAnswerCall: {
                                presentVoiceCallDirectly()
                            },
                            attachmentRequest: model.attachmentRequest
                        )
                        .allowsHitTesting(selectedMessageIDs == nil)
                        .padding(.leading, selectedMessageIDs != nil && Self.isSelectable(message) ? 34 : 0)
                        .overlay(alignment: .leading) {
                            if let selected = selectedMessageIDs, Self.isSelectable(message) {
                                selectionMark(isOn: selected.contains(message.id))
                                    .padding(.leading, 12)
                            }
                        }
                        .overlay {
                            if selectedMessageIDs != nil, Self.isSelectable(message) {
                                Color.clear
                                    .contentShape(Rectangle())
                                    .onTapGesture { toggleSelection(message.id) }
                            }
                        }
                        .id(message.id)
                    }

                    if !model.streamingThinking.isEmpty {
                        StreamingProcessRow(
                            title: "Thought process",
                            text: model.streamingThinking,
                            palette: palette,
                            isPaper: model.theme == .paper,
                            isMist: model.theme == .mist,
                            isNest: model.theme == .nest,
                            showsAIAvatar: model.showsAIAvatar,
                            aiAvatarImage: model.aiAvatarImage,
                            usesUpperTailAvatarLayout: usesUpperTailAvatarLayout,
                            showsAvatarHeader: !historyEndsWithAIThinkingHeader,
                            chatFont: model.chatFont,
                            fontScale: model.fontScale,
                            chatWeight: model.chatWeight
                        )
                    }

                    if !model.streamingReply.isEmpty {
                        StreamingReplyRow(
                            text: model.streamingReply,
                            palette: palette,
                            chatFont: model.chatFont,
                            fontScale: model.fontScale,
                            showsAIAvatar: model.showsAIAvatar,
                            aiAvatarImage: model.aiAvatarImage,
                            showsAIBubble: model.showsAIBubble,
                            aiBubbleColor: model.resolvedAIBubbleColor(default: palette.aiBubble),
                            aiBubbleTextColor: model.resolvedAIBubbleTextColor(default: palette.text),
                            bubbleOpacity: model.aiBubbleOpacity,
                            bubbleRadius: model.bubbleRadius,
                            bubbleWidthScale: model.bubbleWidthScale,
                            bubbleBorderWidth: model.bubbleBorderWidth,
                            bubbleStyle: model.bubbleStyle,
                            bubbleShapeStyle: model.bubbleShapeStyle,
                            liquidGlass: model.liquidGlassSettings,
                            chatWeight: model.chatWeight,
                            isTail: !(model.chatMode == .short && model.bubbleStyle == .classic),
                            isNest: model.theme == .nest,
                            usesUpperTailAvatarLayout: usesUpperTailAvatarLayout,
                            showsAvatarHeader: model.streamingThinking.isEmpty
                                && !historyEndsWithAIThinkingHeader
                        )
                    } else if model.isTyping || !model.streamingThinking.isEmpty {
                        TypingRow(
                            palette: palette,
                            showsAIAvatar: model.showsAIAvatar,
                            aiAvatarImage: model.aiAvatarImage,
                            isNest: model.theme == .nest,
                            usesUpperTailAvatarLayout: usesUpperTailAvatarLayout,
                            showsAvatarHeader: model.streamingThinking.isEmpty
                                && !historyEndsWithAIThinkingHeader
                        )
                    }

                        Color.clear
                            .frame(height: 2)
                            .id("chat-bottom")
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
                    .background {
                        ScrollViewResolver { resolved in
                            if chatScrollView !== resolved { chatScrollView = resolved }
                        }
                        .frame(width: 0, height: 0)
                    }
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    Color.clear.frame(height: topInset)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    Color.clear.frame(height: composerHeight)
                }
                // Extend under the device chrome, but keep the keyboard safe area.
                // Ignoring all bottom safe areas made the last bubble scroll behind
                // the raised composer with no reachable space below it.
                .ignoresSafeArea(.container, edges: [.top, .bottom])
                // The custom fog owns this transition; an automatic system
                // effect at the inset would add a second blur boundary.
                .scrollEdgeEffectHidden(true, for: .top)
                .scrollDismissesKeyboard(.interactively)
                .refreshable { await model.refresh() }
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentSize.height <= geometry.containerSize.height
                        || geometry.visibleRect.maxY >= geometry.contentSize.height - 56
                } action: { _, nextValue in
                    // This fires on every scroll frame. `@State` invalidates on
                    // assignment without comparing, so writing the same value
                    // here re-rendered the whole list ~120 times a second.
                    if nextValue && newMessageCount != 0 { newMessageCount = 0 }
                    if nextValue != isAtBottom { isAtBottom = nextValue }
                }
                // Page older history off the real scroll position rather than
                // the loader row's `onAppear`: a lazy row appearing is a layout
                // event, not a "she scrolled up here" event.
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentSize.height > geometry.containerSize.height
                        && geometry.visibleRect.minY <= geometry.containerSize.height
                } action: { _, nearTop in
                    guard nearTop, canTriggerOlderHistory, model.canLoadOlderHistory else { return }
                    prependOlderHistory(using: proxy)
                }
                .onAppear { positionInitialHistoryIfNeeded(proxy) }
                .onChange(of: model.messages.count) { count in
                    let previousCount = observedMessageCount
                    observedMessageCount = count
                    guard !isPrependingHistory else { return }
                    guard didPositionInitialHistory else {
                        guard !model.isLoadingHistory, !model.messages.isEmpty else { return }
                        didPositionInitialHistory = true
                        settleAtBottom(proxy)
                        return
                    }
                    guard !model.isLoadingHistory else { return }
                    let sentByMe = model.messages.last?.author == .human
                    if !isAtBottom, !sentByMe, count > previousCount {
                        let appended = model.messages.suffix(count - previousCount)
                        let incomingCount = appended.filter {
                            $0.author == .ai && $0.kind != "thinking" && $0.kind != "act"
                        }.count
                        newMessageCount += incomingCount
                    }
                    guard isAtBottom || sentByMe else { return }
                    scrollToBottom(proxy, animated: true)
                }
                .onChange(of: model.isLoadingHistory) { loading in
                    if loading {
                        newMessageCount = 0
                        observedMessageCount = model.messages.count
                    }
                    guard !loading, !model.messages.isEmpty else { return }
                    guard !didPositionInitialHistory else { return }
                    didPositionInitialHistory = true
                    settleAtBottom(proxy)
                }
                .onChange(of: model.streamingReply) { _ in
                    if isAtBottom { scrollToBottom(proxy, animated: false) }
                }
                .onChange(of: model.streamingThinking) { _ in
                    if isAtBottom { scrollToBottom(proxy, animated: false) }
                }
                .onChange(of: model.isTyping) { _ in
                    if isAtBottom { scrollToBottom(proxy, animated: true) }
                }
                .onChange(of: viewport.size.height) { _ in
                    guard isAtBottom else { return }
                    scrollToBottom(proxy, animated: false)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                        scrollToBottom(proxy, animated: false)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                    // Match the PWA: focusing the composer settles the latest
                    // bubble above the keyboard — but only when she was already
                    // reading the latest bubble. Forcing it while she is up in
                    // history is what made tapping the composer feel like the
                    // list teleported.
                    guard isAtBottom else { return }
                    if newMessageCount != 0 { newMessageCount = 0 }
                    // One settle, after the keyboard has finished raising the
                    // safe-area inset. An animated `setContentOffset` launched
                    // mid-animation fights UIKit's own inset adjustment.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
                        guard isAtBottom else { return }
                        scrollToBottom(proxy, animated: false)
                    }
                }
                .onChange(of: model.navigationRequest) { request in
                    guard let request else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            proxy.scrollTo(request.messageID, anchor: .center)
                        }
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    // Keep the implicit animation scoped to the jump button.
                    // Hanging it off the ScrollView animated the entire message
                    // list every time `isAtBottom` flipped mid-scroll.
                    ZStack(alignment: .bottomTrailing) {
                        if !isAtBottom {
                            HStack(spacing: 8) {
                                if newMessageCount > 0 {
                                    Button {
                                        newMessageCount = 0
                                        jumpToBottom(proxy)
                                    } label: {
                                        HStack(spacing: 6) {
                                            Circle()
                                                .fill(palette.accent)
                                                .frame(width: 6, height: 6)
                                            Text(newMessageCount > 99 ? "99+ 条新消息" : "\(newMessageCount) 条新消息")
                                                .font(.system(size: 12, weight: .medium))
                                        }
                                        .foregroundStyle(palette.text)
                                        .padding(.horizontal, 12)
                                        .frame(height: 34)
                                        .background(.ultraThinMaterial, in: Capsule())
                                        .overlay(Capsule().stroke(palette.hairline, lineWidth: 0.5))
                                        .shadow(color: Color.black.opacity(0.07), radius: 8, y: 3)
                                    }
                                    .buttonStyle(.plain)
                                    .transition(.move(edge: .bottom).combined(with: .opacity))
                                    .accessibilityLabel("\(newMessageCount) 条新消息，回到最新位置")
                                }

                                Button {
                                    newMessageCount = 0
                                    jumpToBottom(proxy)
                                } label: {
                                    Image(systemName: "arrow.down")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(palette.text)
                                        .frame(width: 36, height: 36)
                                        .background(.ultraThinMaterial, in: Circle())
                                        .overlay(Circle().stroke(palette.hairline, lineWidth: 0.5))
                                        .shadow(color: Color.black.opacity(0.08), radius: 8, y: 3)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("回到最新消息")
                            }
                            .padding(.trailing, 16)
                            .padding(.bottom, composerHeight + 12)
                            .transition(.scale(scale: 0.88).combined(with: .opacity))
                        }
                    }
                    .animation(.easeOut(duration: 0.18), value: isAtBottom)
                    .animation(.easeOut(duration: 0.18), value: newMessageCount)
                }
            }
        }
    }

    private func positionInitialHistoryIfNeeded(_ proxy: ScrollViewProxy) {
        guard !model.isLoadingHistory, !model.messages.isEmpty else { return }
        didPositionInitialHistory = true
        settleAtBottom(proxy)
    }

    /// Every row needs to know how it groups with its neighbours. Deriving that
    /// per row used to cost four `firstIndex(where:)` scans plus a handful of
    /// freshly allocated `ISO8601DateFormatter`s — quadratic work on every body
    /// pass, which is what made scrolling feel sticky. Build the whole plan in
    /// one forward pass instead.
    private static func isSelectable(_ message: ChatMessage) -> Bool {
        message.id > 0 && !["thinking", "act", "call"].contains(message.kind)
    }

    /// In chat order, whatever order they were tapped in.
    private var selectedMessages: [ChatMessage] {
        guard let ids = selectedMessageIDs else { return [] }
        return model.messages.filter { ids.contains($0.id) }
    }

    private func selectionMark(isOn: Bool) -> some View {
        Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 22, weight: .regular))
            .foregroundStyle(isOn ? palette.accent : palette.secondaryText.opacity(0.7))
            .background(Circle().fill(palette.background.opacity(isOn ? 1 : 0.6)).padding(2))
            .accessibilityLabel(isOn ? "已选中" : "未选中")
    }

    private func toggleSelection(_ id: Int) {
        guard var ids = selectedMessageIDs else { return }
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        selectedMessageIDs = ids
    }

    private func starSelection() {
        let targets = selectedMessages
        guard !targets.isEmpty, !isWorkingOnSelection else { return }
        let turnOn = !targets.allSatisfy { $0.meta.starred != nil }
        isWorkingOnSelection = true
        Task {
            defer { isWorkingOnSelection = false }
            for message in targets where (message.meta.starred != nil) != turnOn {
                do {
                    try await model.setStar(messageID: message.id, on: turnOn)
                } catch {
                    model.errorMessage = error.localizedDescription
                    return
                }
            }
            withAnimation(.easeOut(duration: 0.18)) { selectedMessageIDs = nil }
        }
    }

    private func shareSelection() {
        let messages = selectedMessages
        guard !messages.isEmpty, !isWorkingOnSelection else { return }
        guard messages.count <= 60 else {
            model.errorMessage = "一张卡片最多放 60 条消息，少选几条再试。"
            return
        }
        isWorkingOnSelection = true
        let style = MessageShareStyle(
            palette: palette,
            aiFont: model.chatFont,
            humanFont: model.resolvedHumanChatFont,
            aiScale: model.fontScale,
            humanScale: model.humanFontScale,
            weight: model.chatWeight,
            aiBubble: model.resolvedAIBubbleColor(default: palette.aiBubble),
            humanBubble: model.resolvedHumanBubbleColor(default: palette.humanBubble),
            aiText: model.resolvedAIBubbleTextColor(default: palette.text),
            humanText: model.resolvedHumanBubbleTextColor(default: palette.text),
            aiOpacity: model.showsAIBubble ? model.aiBubbleOpacity : 0,
            humanOpacity: model.humanBubbleOpacity,
            radius: CGFloat(model.bubbleRadius),
            aiAvatar: model.aiAvatarImage,
            humanAvatar: model.humanAvatarImage,
            aiName: model.peerDisplayName,
            humanName: "小雪"
        )
        Task {
            defer { isWorkingOnSelection = false }
            let images = await loadShareImages(for: messages)
            guard let image = MessageShareCard.render(messages: messages, images: images, style: style) else {
                model.errorMessage = "卡片没画出来，请再试一次。"
                return
            }
            shareCard = ShareCardImage(image: image)
        }
    }

    /// Photos must be downloaded before rendering; the card cannot wait for them.
    private func loadShareImages(for messages: [ChatMessage]) async -> [String: UIImage] {
        let attachments = messages
            .flatMap { $0.meta.attachments }
            .filter { $0.isImage && $0.xhs != true }
            .prefix(18)
        var images: [String: UIImage] = [:]
        for attachment in attachments {
            guard let request = model.attachmentRequest(for: attachment),
                  let result = try? await URLSession.shared.data(for: request),
                  let http = result.1 as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let image = UIImage(data: result.0) else { continue }
            images[attachment.id] = image
        }
        return images
    }

    private var chatRows: [ChatRow] {
        Self.buildRows(
            model.messages,
            liveAIReplyFollowsHistory: !model.streamingReply.isEmpty
        )
    }

    private var latestAIReplyID: Int? {
        model.messages.last(where: {
            $0.id > 0
                && $0.author == .ai
                && $0.kind == "reply"
                && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })?.id
    }

    private static func buildRows(
        _ messages: [ChatMessage],
        liveAIReplyFollowsHistory: Bool
    ) -> [ChatRow] {
        guard !messages.isEmpty else { return [] }
        var rows: [ChatRow] = []
        rows.reserveCapacity(messages.count)
        // In the upper-corner layout, Thinking owns the AI identity header for
        // the reply that follows it, so the first reply bubble does not repeat it.
        var activeAIThinkingHeader: ChatMessage?
        for index in messages.indices {
            let message = messages[index]
            let isGroupStart: Bool
            if index > 0 {
                isGroupStart = !messagesShareBubbleGroup(messages[index - 1], message)
            } else {
                isGroupStart = true
            }

            var isTail = true
            if message.kind != "thinking", message.kind != "act", index + 1 < messages.count {
                isTail = !messagesShareBubbleGroup(message, messages[index + 1])
            }

            if let thinkingHeader = activeAIThinkingHeader,
               !messagesShareAvatarBurst(thinkingHeader, message) {
                activeAIThinkingHeader = nil
            }
            let showsAvatarHeader: Bool
            if message.author == .human {
                activeAIThinkingHeader = nil
                showsAvatarHeader = isGroupStart
            } else if message.kind == "thinking" {
                let ownsReplyAvatar = hasFollowingAIReply(
                    after: index,
                    in: messages,
                    liveAIReplyFollowsHistory: liveAIReplyFollowsHistory
                )
                showsAvatarHeader = activeAIThinkingHeader == nil && ownsReplyAvatar
                if showsAvatarHeader { activeAIThinkingHeader = message }
            } else if message.kind == "act" {
                showsAvatarHeader = false
            } else {
                showsAvatarHeader = isGroupStart && activeAIThinkingHeader == nil
                activeAIThinkingHeader = nil
            }

            rows.append(
                ChatRow(
                    message: message,
                    showsTimestamp: showsTimestamp(at: index, in: messages),
                    isGroupStart: isGroupStart,
                    showsAvatarHeader: showsAvatarHeader,
                    isTail: isTail
                )
            )
        }
        return rows
    }

    /// In the upper-corner layout, Thinking borrows the avatar from the reply it
    /// introduces. A thought-only turn has no reply bubble, so it must not leave
    /// a standalone avatar beside the Thinking disclosure.
    private static func hasFollowingAIReply(
        after index: Int,
        in messages: [ChatMessage],
        liveAIReplyFollowsHistory: Bool
    ) -> Bool {
        let thinking = messages[index]
        var cursor = index + 1
        while cursor < messages.count {
            let candidate = messages[cursor]
            guard messagesShareAvatarBurst(thinking, candidate) else { return false }
            if candidate.kind == "reply" { return true }
            cursor += 1
        }
        return liveAIReplyFollowsHistory
    }

    private static func messagesShareAvatarBurst(
        _ first: ChatMessage,
        _ second: ChatMessage
    ) -> Bool {
        guard first.author == second.author,
              let date = messageDate(first.timestamp),
              let nextDate = messageDate(second.timestamp),
              EchoDateCache.shanghaiCalendar.isDate(date, inSameDayAs: nextDate) else { return false }
        let interval = nextDate.timeIntervalSince(date)
        return interval >= 0 && interval < 5 * 60
    }

    private static func showsTimestamp(at index: Int, in messages: [ChatMessage]) -> Bool {
        let message = messages[index]
        if message.kind == "thinking" || message.kind == "act" { return false }
        var cursor = index + 1
        while cursor < messages.count {
            let next = messages[cursor]
            if next.kind == "thinking" || next.kind == "act" {
                cursor += 1
                continue
            }
            guard next.author == message.author,
                  let date = messageDate(message.timestamp),
                  let nextDate = messageDate(next.timestamp) else { return true }
            let interval = nextDate.timeIntervalSince(date)
            // 小雪连续发消息时，只在最后一条下面落时间；AI 的原有节奏保持不变。
            let burstWindow = message.author == .human ? 3 * 60.0 : 2 * 60.0
            return interval < 0 || interval > burstWindow
        }
        return true
    }

    private var newestUnansweredAskID: Int? {
        model.messages.last(where: {
            $0.id > 0 && $0.meta.ask != nil && $0.meta.ask?.answer == nil
        })?.id
    }

    private func primeAskAutopresentationIfNeeded() {
        guard !model.isLoadingHistory, !didPrimeAskAutopresentation else { return }
        seenAskMessageIDs = Set(model.messages.compactMap { message in
            message.meta.ask == nil ? nil : message.id
        })
        didPrimeAskAutopresentation = true
    }

    private func presentNewestAskIfNeeded() {
        guard !model.isLoadingHistory else { return }
        guard didPrimeAskAutopresentation else {
            primeAskAutopresentationIfNeeded()
            return
        }
        guard let message = model.messages.last(where: {
            $0.id > 0 && $0.meta.ask != nil && $0.meta.ask?.answer == nil
        }), let ask = message.meta.ask,
              !seenAskMessageIDs.contains(message.id) else { return }
        seenAskMessageIDs.insert(message.id)
        askSheetContext = AskSheetContext(messageID: message.id, initialAsk: ask)
    }

    private var newestPendingPeekID: Int? {
        model.messages.last(where: {
            $0.id > 0 && $0.meta.peek?.status == "pending"
        })?.id
    }

    private func primePeekAutopresentationIfNeeded() {
        guard !model.isLoadingHistory, !didPrimePeekAutopresentation else { return }
        seenPeekMessageIDs = Set(model.messages.compactMap { message in
            message.meta.peek == nil ? nil : message.id
        })
        didPrimePeekAutopresentation = true
    }

    private func presentNewestPeekIfNeeded() {
        guard !model.isLoadingHistory else { return }
        guard didPrimePeekAutopresentation else {
            primePeekAutopresentationIfNeeded()
            return
        }
        guard let message = model.messages.last(where: {
            $0.id > 0 && $0.meta.peek?.status == "pending"
        }), let peek = message.meta.peek,
              !seenPeekMessageIDs.contains(message.id) else { return }
        seenPeekMessageIDs.insert(message.id)
        peekSheetContext = PeekSheetContext(messageID: message.id, initialPeek: peek)
    }

    private static func messagesShareBubbleGroup(_ first: ChatMessage, _ second: ChatMessage) -> Bool {
        guard first.kind != "thinking", first.kind != "act",
              second.kind != "thinking", second.kind != "act",
              first.author == second.author,
              let date = messageDate(first.timestamp),
              let nextDate = messageDate(second.timestamp) else { return false }
        guard EchoDateCache.shanghaiCalendar.isDate(date, inSameDayAs: nextDate) else { return false }
        let interval = nextDate.timeIntervalSince(date)
        return interval >= 0 && interval < 5 * 60
    }

    private static func messageDate(_ raw: String) -> Date? {
        EchoDateCache.date(from: raw)
    }

    private func settleAtBottom(_ proxy: ScrollViewProxy) {
        scrollToBottom(proxy, animated: false)
        // Lazy rows and authenticated images finish their first layout on later passes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            scrollToBottom(proxy, animated: false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            canTriggerOlderHistory = true
        }
    }

    private func prependOlderHistory(using proxy: ScrollViewProxy) {
        // Never page while she is pinned to the newest message: the anchor
        // restore below would throw her back to where the old window started.
        guard !isPrependingHistory, !model.isLoadingOlderHistory, !isAtBottom else { return }
        isPrependingHistory = true
        Task {
            let anchor = await model.loadOlderHistory()
            DispatchQueue.main.async {
                if let anchor { proxy.scrollTo(anchor, anchor: .top) }
                isPrependingHistory = false
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let scrollView = chatScrollView else {
            DispatchQueue.main.async {
                if animated {
                    withAnimation(.easeOut(duration: 0.24)) {
                        proxy.scrollTo("chat-bottom", anchor: .bottom)
                    }
                } else {
                    proxy.scrollTo("chat-bottom", anchor: .bottom)
                }
            }
            return
        }
        let distance = abs(bottomOffset(for: scrollView) - scrollView.contentOffset.y)
        let shouldAnimate = animated && distance <= max(scrollView.bounds.height * 1.8, 900)
        setExactBottom(on: scrollView, animated: shouldAnimate)
    }

    private func jumpToBottom(_ proxy: ScrollViewProxy) {
        guard let scrollView = chatScrollView else {
            scrollToBottom(proxy, animated: false)
            return
        }

        scrollView.layoutIfNeeded()
        let destination = bottomOffset(for: scrollView)
        let distance = abs(destination - scrollView.contentOffset.y)
        let shouldAnimate = distance <= max(scrollView.bounds.height * 1.8, 900)
        setExactBottom(on: scrollView, animated: shouldAnimate)

        // Lazy rows can refine their heights after a long jump. Re-read the
        // real UIKit content size and settle again instead of trusting an
        // estimated SwiftUI row position.
        for delay in [0.10, 0.32] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard chatScrollView === scrollView else { return }
                setExactBottom(on: scrollView, animated: false)
            }
        }
    }

    private func setExactBottom(on scrollView: UIScrollView, animated: Bool) {
        scrollView.layoutIfNeeded()
        scrollView.setContentOffset(
            CGPoint(x: scrollView.contentOffset.x, y: bottomOffset(for: scrollView)),
            animated: animated
        )
    }

    private func bottomOffset(for scrollView: UIScrollView) -> CGFloat {
        max(
            -scrollView.adjustedContentInset.top,
            scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
        )
    }

    private struct ScrollViewResolver: UIViewRepresentable {
        let onResolve: (UIScrollView) -> Void

        func makeUIView(context: Context) -> UIView {
            let view = UIView(frame: .zero)
            resolve(from: view)
            return view
        }

        func updateUIView(_ uiView: UIView, context: Context) {
            resolve(from: uiView)
        }

        private func resolve(from view: UIView) {
            DispatchQueue.main.async {
                var candidate = view.superview
                while let current = candidate {
                    if let scrollView = current as? UIScrollView {
                        onResolve(scrollView)
                        return
                    }
                    candidate = current.superview
                }
            }
        }
    }

    private func openAcceptedCallIfNeeded() {
        guard nativeCalls.acceptedInvite != nil, !showingVoiceCall else { return }
        presentVoiceCallDirectly()
    }

    private func presentVoiceCallDirectly() {
        guard !showingVoiceCall, !isPresentingVoiceCall else { return }
        isPresentingVoiceCall = true
        Task {
            if let invite = nativeCalls.acceptedInvite {
                guard await model.prepareIncomingCall(messageID: invite.id) else {
                    isPresentingVoiceCall = false
                    return
                }
            }
            await nativeCalls.transitionToInAppCall()
            showingVoiceCall = true
            isPresentingVoiceCall = false
        }
    }
}

/// One chat bubble plus the grouping decisions its neighbours imply, resolved
/// once per list build instead of once per row.
private struct ChatRow: Identifiable {
    let message: ChatMessage
    let showsTimestamp: Bool
    let isGroupStart: Bool
    let showsAvatarHeader: Bool
    let isTail: Bool

    var id: Int { message.id }
}

private struct AskSheetContext: Identifiable {
    let messageID: Int
    let initialAsk: MessageAsk
    var id: Int { messageID }
}

private struct PeekSheetContext: Identifiable {
    let messageID: Int
    let initialPeek: MessagePeek
    var id: Int { messageID }
}

/// 我开口要看她屏幕时从底部升起来的那张卡。按「给你看」之后，系统自己的录屏
/// 面板会接着弹出来——那一下 iOS 不让代码代劳，所以这里把话说在前面。
private struct MessagePeekSheet: View {
    @ObservedObject var model: AppModel
    let context: PeekSheetContext
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false

    private var palette: EchoPalette { model.theme.palette }
    private var peek: MessagePeek {
        model.messages.first(where: { $0.id == context.messageID })?.meta.peek ?? context.initialPeek
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Text("ALTAIR 想看一眼")
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(1.5)
                    .foregroundStyle(palette.accent)
                    .padding(.top, 5)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(palette.secondaryText)
                        .frame(width: 32, height: 32)
                        .background(palette.composer.opacity(0.82), in: Circle())
                }
                .buttonStyle(.plain)
            }

            Text(peek.note.isEmpty ? "让我看看你此刻的屏幕。" : peek.note)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(palette.text)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)

            Text("点「给你看」，系统会弹出录屏面板——在那上面点一下开始直播就行。只取一张画面，然后自动结束。")
                .font(.system(size: 13))
                .foregroundStyle(palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)

            Spacer(minLength: 16)

            HStack(spacing: 10) {
                Button {
                    guard !busy else { return }
                    busy = true
                    // 先让这张卡退场，系统面板才好干净地盖上来
                    dismiss()
                    Task {
                        do { try await model.acceptPeek(messageID: context.messageID) }
                        catch { model.errorMessage = error.localizedDescription }
                    }
                } label: {
                    Text("给你看")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(palette.onAccent)
                        .frame(maxWidth: .infinity, minHeight: 46)
                }
                .buttonStyle(.borderedProminent)
                .tint(palette.accent)

                Button {
                    guard !busy else { return }
                    busy = true
                    Task {
                        do { try await model.declinePeek(messageID: context.messageID) }
                        catch { model.errorMessage = error.localizedDescription }
                        dismiss()
                    }
                } label: {
                    Text("现在不行")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(palette.text)
                        .frame(maxWidth: .infinity, minHeight: 46)
                }
                .buttonStyle(.bordered)
                .tint(palette.secondaryText)
            }
            .disabled(busy)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(palette.background.ignoresSafeArea())
        .onChange(of: peek.status) { _, status in
            // 别的设备上按过了（或者卡过期了），这边就别再挡着
            if status != "pending" && !busy { dismiss() }
        }
    }
}

private struct MessageAskSheet: View {
    @ObservedObject var model: AppModel
    let context: AskSheetContext
    @Environment(\.dismiss) private var dismiss
    @State private var freeText = ""
    @State private var isSubmitting = false
    @State private var errorText: String?
    @FocusState private var freeAnswerFocused: Bool

    private var palette: EchoPalette { model.theme.palette }
    private var accentForeground: Color {
        palette.onAccent
    }
    private var ask: MessageAsk {
        model.messages.first(where: { $0.id == context.messageID })?.meta.ask ?? context.initialAsk
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top) {
                        Text("ALTAIR 在问")
                            .font(.system(size: 12, weight: .semibold))
                            .tracking(1.5)
                            .foregroundStyle(palette.accent)
                            .padding(.top, 5)
                        Spacer()
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(palette.secondaryText)
                                .frame(width: 32, height: 32)
                                .background(palette.composer.opacity(0.82), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("关闭")
                    }

                    Text(ask.question)
                        .font(model.chatFont.font(size: 17 * model.fontScale, numericWeight: max(450, model.chatWeight)))
                        .foregroundStyle(palette.text)
                        .lineSpacing(6)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 5)
                        .padding(.bottom, 15)

                    VStack(spacing: 0) {
                        ForEach(Array(ask.options.enumerated()), id: \.offset) { index, option in
                            Button { submit(index: index) } label: {
                                HStack(spacing: 12) {
                                    Text(optionNumber(for: index))
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(isPicked(index) ? accentForeground : palette.secondaryText)
                                        .frame(width: 28, height: 28)
                                        .background(
                                            isPicked(index) ? palette.accent : palette.composer,
                                            in: Circle()
                                        )
                                    Text(option)
                                        .font(model.chatFont.font(size: 15 * model.fontScale, numericWeight: model.chatWeight))
                                        .foregroundStyle(palette.text)
                                        .multilineTextAlignment(.leading)
                                    Spacer(minLength: 8)
                                    Image(systemName: isPicked(index) ? "checkmark" : "chevron.right")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(isPicked(index) ? palette.accent : palette.secondaryText)
                                }
                                .padding(.vertical, 13)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(ask.answer != nil || isSubmitting)
                            .opacity(ask.answer == nil || isPicked(index) ? 1 : 0.42)

                            Divider().overlay(palette.hairline)
                        }
                    }

                    if let answer = ask.answer {
                        Text(answer.kind == "free" ? "你自己答的：「\(answer.text)」" : "答过了，不许改口。")
                            .font(.system(size: 13))
                            .foregroundStyle(palette.secondaryText)
                            .padding(.top, 16)
                    } else {
                        HStack(spacing: 9) {
                            TextField("我偏要自己答", text: $freeText)
                                .font(model.chatFont.font(size: 14 * model.fontScale, numericWeight: model.chatWeight))
                                .foregroundStyle(palette.text)
                                .focused($freeAnswerFocused)
                                .submitLabel(.send)
                                .onSubmit { submitFreeAnswer() }
                                .padding(.horizontal, 15)
                                .frame(height: 42)
                                .background(palette.composer.opacity(0.82), in: Capsule())
                                .overlay(Capsule().stroke(palette.hairline, lineWidth: 0.6))

                            Button { submitFreeAnswer() } label: {
                                if isSubmitting {
                                    ProgressView().controlSize(.small).tint(accentForeground)
                                } else {
                                    Image(systemName: "arrow.up")
                                        .font(.system(size: 15, weight: .bold))
                                }
                            }
                            .foregroundStyle(accentForeground)
                            .frame(width: 42, height: 42)
                            .background(palette.accent, in: Circle())
                            .disabled(freeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmitting)
                            .opacity(freeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.42 : 1)
                        }
                        .padding(.top, 16)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 28)
            }
            .scrollDismissesKeyboard(.interactively)
            .background {
                if model.theme == .mist {
                    Color.white.ignoresSafeArea()
                } else {
                    palette.background.ignoresSafeArea()
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .preferredColorScheme(model.theme.preferredColorScheme)
        .alert("没答上", isPresented: Binding(
            get: { errorText != nil },
            set: { if !$0 { errorText = nil } }
        )) {
            Button("好", role: .cancel) { errorText = nil }
        } message: {
            Text(errorText ?? "请再试一次。")
        }
    }

    private func optionNumber(for index: Int) -> String {
        String(index + 1)
    }

    private func isPicked(_ index: Int) -> Bool {
        ask.answer?.kind == "pick" && ask.answer?.index == index
    }

    private func submitFreeAnswer() {
        let text = freeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        submit(text: String(text.prefix(200)))
    }

    private func submit(index: Int? = nil, text: String? = nil) {
        guard ask.answer == nil, !isSubmitting else { return }
        isSubmitting = true
        freeAnswerFocused = false
        Task {
            do {
                try await model.answerAsk(messageID: context.messageID, index: index, text: text)
                try? await Task.sleep(nanoseconds: 800_000_000)
                dismiss()
            } catch {
                errorText = error.localizedDescription
                isSubmitting = false
            }
        }
    }
}

private struct MessageSearchView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [ChatMessage] = []
    @State private var isSearching = false
    @State private var isOpening = false
    @State private var errorText: String?

    private var palette: EchoPalette { model.theme.palette }

    var body: some View {
        NavigationStack {
            List {
                if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && results.isEmpty && !isSearching {
                    VStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 28, weight: .light))
                        Text("没有找到相关聊天")
                    }
                    .foregroundStyle(palette.secondaryText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 70)
                    .listRowBackground(Color.clear)
                }

                ForEach(results) { message in
                    Button {
                        guard !isOpening else { return }
                        isOpening = true
                        Task {
                            await model.jumpToMessage(message)
                            dismiss()
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(spacing: 7) {
                                Text(message.author == .human ? "小雪" : model.peerDisplayName)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(message.author == .ai ? palette.accent : palette.text)
                                Text(model.sessionTitle(for: message))
                                    .font(.caption2)
                                    .foregroundStyle(palette.secondaryText)
                                Spacer()
                                Text(Self.shortDate(message.timestamp))
                                    .font(.caption2)
                                    .foregroundStyle(palette.secondaryText)
                            }
                            Text(message.text.isEmpty ? "[附件]" : message.text)
                                .font(model.chatFont.font(size: 15, weight: model.chatWeight.echoFontWeight))
                                .foregroundStyle(palette.text)
                                .lineLimit(3)
                                .multilineTextAlignment(.leading)
                        }
                        .padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)
                }
            }
            .overlay {
                if isSearching { ProgressView("正在搜索…").tint(palette.accent) }
                else if query.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "text.magnifyingglass")
                            .font(.system(size: 31, weight: .light))
                        Text("搜索所有窗口里的聊天记录")
                    }
                    .foregroundStyle(palette.secondaryText)
                }
            }
            .scrollContentBackground(.hidden)
            .background(palette.background.ignoresSafeArea())
            .navigationTitle("搜索聊天记录")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "输入关键词")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } }
            }
            .task(id: query) {
                let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    results = []
                    isSearching = false
                    errorText = nil
                    return
                }
                let searchedQuery = trimmed
                isSearching = true
                errorText = nil
                do {
                    try await Task.sleep(nanoseconds: 280_000_000)
                    guard !Task.isCancelled else { return }
                    let nextResults = try await model.searchMessages(searchedQuery)
                    guard !Task.isCancelled,
                          query.trimmingCharacters(in: .whitespacesAndNewlines) == searchedQuery else { return }
                    results = nextResults
                    errorText = nil
                } catch is CancellationError {
                    return
                } catch let error as URLError where error.code == .cancelled {
                    return
                } catch {
                    guard query.trimmingCharacters(in: .whitespacesAndNewlines) == searchedQuery else { return }
                    results = []
                    errorText = error.localizedDescription
                }
                if query.trimmingCharacters(in: .whitespacesAndNewlines) == searchedQuery {
                    isSearching = false
                }
            }
            .alert("搜索失败", isPresented: Binding(
                get: { errorText != nil },
                set: { if !$0 { errorText = nil } }
            )) {
                Button("好", role: .cancel) { errorText = nil }
            } message: {
                Text(errorText ?? "")
            }
        }
        .tint(palette.accent)
        .presentationDetents([.large])
    }

    private static func shortDate(_ raw: String) -> String {
        let input = ISO8601DateFormatter()
        input.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = input.date(from: raw) ?? ISO8601DateFormatter().date(from: raw) else { return "" }
        let output = DateFormatter()
        output.locale = Locale(identifier: "zh_CN")
        output.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "M月d日"
        return output.string(from: date)
    }
}

private struct SessionManagerView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var renamingSession: APISession?
    @State private var renameText = ""
    @State private var deletingSession: APISession?
    @State private var isCreating = false
    @State private var errorText: String?

    private var palette: EchoPalette { model.theme.palette }

    var body: some View {
        NavigationStack {
            List {
                Section("对话窗口") {
                    sessionButton(id: AppModel.legacySessionID, title: "Claude Code", subtitle: "Claude Code / Desktop 会话记录")
                    ForEach(model.sessions) { session in
                        sessionButton(
                            id: session.id,
                            title: session.title,
                            subtitle: "\(session.body == .codex ? "Codex" : "API") · 从消息 #\(session.sinceID) 开始"
                        )
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) { deletingSession = session } label: {
                                Label("删除", systemImage: "trash")
                            }
                            Button {
                                renameText = session.title
                                renamingSession = session
                            } label: {
                                Label("改名", systemImage: "pencil")
                            }
                            .tint(palette.accent)
                        }
                    }
                }

                if model.sessions.isEmpty && !model.isLoadingSessions {
                    Section {
                        Text("可以新建独立的 Codex 或 API 窗口；每个窗口保留自己的上下文。")
                            .font(.footnote)
                            .foregroundStyle(palette.secondaryText)
                    }
                }
            }
            .overlay { if model.isLoadingSessions { ProgressView("读取对话窗口…") } }
            .scrollContentBackground(.hidden)
            .background {
                Group {
                    if model.theme == .mist {
                        Color.white
                    } else {
                        palette.background
                    }
                }
                .ignoresSafeArea()
            }
            .navigationTitle("对话窗口")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    if isCreating {
                        ProgressView().controlSize(.small)
                    } else {
                        Menu {
                            Button {
                                createSession(body: .codex)
                            } label: {
                                Label("Codex 窗口", systemImage: "chevron.left.forwardslash.chevron.right")
                            }
                            Button {
                                createSession(body: .loop)
                            } label: {
                                Label("API 窗口", systemImage: "network")
                            }
                        } label: {
                            Image(systemName: "plus")
                        }
                    }
                }
            }
            .task { await model.refreshSessions() }
            .alert("重命名对话", isPresented: Binding(
                get: { renamingSession != nil },
                set: { if !$0 { renamingSession = nil } }
            )) {
                TextField("对话名称", text: $renameText)
                Button("保存") {
                    guard let session = renamingSession else { return }
                    renamingSession = nil
                    Task {
                        do { try await model.renameSession(id: session.id, title: renameText) }
                        catch { errorText = error.localizedDescription }
                    }
                }
                Button("取消", role: .cancel) { renamingSession = nil }
            }
            .confirmationDialog(
                "删除这个对话窗口？",
                isPresented: Binding(
                    get: { deletingSession != nil },
                    set: { if !$0 { deletingSession = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("删除窗口和其中记录", role: .destructive) {
                    guard let session = deletingSession else { return }
                    deletingSession = nil
                    Task {
                        do { try await model.deleteSession(id: session.id) }
                        catch { errorText = error.localizedDescription }
                    }
                }
                Button("取消", role: .cancel) { deletingSession = nil }
            } message: {
                Text("服务器里的这个窗口及聊天记录会被永久删除。")
            }
            .alert("对话操作失败", isPresented: Binding(
                get: { errorText != nil },
                set: { if !$0 { errorText = nil } }
            )) {
                Button("好", role: .cancel) { errorText = nil }
            } message: {
                Text(errorText ?? "")
            }
        }
        .tint(palette.accent)
        .presentationDetents([.medium, .large])
    }

    private func sessionButton(id: String, title: String, subtitle: String) -> some View {
        Button {
            Task {
                await model.activateSession(id)
                dismiss()
            }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.body.weight(.medium)).foregroundStyle(palette.text)
                    Text(subtitle).font(.caption).foregroundStyle(palette.secondaryText)
                }
                Spacer()
                if model.activeSessionID == id {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(palette.accent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func createSession(body: BrainTarget) {
        guard !isCreating else { return }
        isCreating = true
        Task {
            defer { isCreating = false }
            do {
                try await model.createSession(body: body)
                dismiss()
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}

private struct EditMessageView: View {
    @ObservedObject var model: AppModel
    let message: ChatMessage
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var isSaving = false
    @State private var errorText: String?

    init(model: AppModel, message: ChatMessage) {
        self.model = model
        self.message = message
        _text = State(initialValue: message.text)
    }

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .font(model.chatFont.font(size: 17, weight: model.chatWeight.echoFontWeight))
                .padding(12)
                .navigationTitle("编辑消息")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        if isSaving { ProgressView().controlSize(.small) }
                        else {
                            Button("保存") {
                                isSaving = true
                                Task {
                                    do {
                                        try await model.editMessage(id: message.id, text: text)
                                        dismiss()
                                    } catch {
                                        isSaving = false
                                        errorText = error.localizedDescription
                                    }
                                }
                            }
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
                .alert("编辑失败", isPresented: Binding(
                    get: { errorText != nil },
                    set: { if !$0 { errorText = nil } }
                )) {
                    Button("好", role: .cancel) { errorText = nil }
                } message: {
                    Text(errorText ?? "")
                }
        }
        .tint(model.theme.palette.accent)
        .presentationDetents([.medium, .large])
    }
}

private struct NativeIncomingCallOverlay: View {
    @ObservedObject var model: AppModel
    let invite: IncomingCallInvite
    let onAccept: () -> Void
    let onDecline: () -> Void
    @StateObject private var ringer = IncomingCallRinger()

    private var palette: EchoPalette { model.theme.palette }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [palette.backgroundTop, palette.backgroundBottom, palette.accent.opacity(0.25)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Text("incoming call")
                    .font(.caption.weight(.semibold))
                    .tracking(2)
                    .foregroundStyle(palette.secondaryText)
                    .padding(.top, 72)

                Spacer()

                Group {
                    if let image = model.aiAvatarImage {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Image(systemName: "sparkles")
                            .font(.system(size: 45, weight: .light))
                            .foregroundStyle(palette.accent)
                            .background(palette.aiBubble)
                    }
                }
                .frame(width: 134, height: 134)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.6), lineWidth: 1))
                .shadow(color: palette.accent.opacity(0.25), radius: 28)
                .scaleEffect(ringer.pulse ? 1.025 : 0.98)

                Text("\(model.peerDisplayName)来电")
                    .font(.system(size: 29, weight: .semibold, design: .serif))
                    .foregroundStyle(palette.text)
                    .padding(.top, 24)
                Text(invite.text)
                    .font(.subheadline)
                    .foregroundStyle(palette.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 36)
                    .padding(.top, 10)

                Spacer()

                HStack(spacing: 82) {
                    incomingAction(title: "拒绝", icon: "phone.down.fill", color: .red, action: onDecline)
                    incomingAction(title: "接听", icon: "phone.fill", color: .green, action: onAccept)
                }
                .padding(.bottom, 62)
            }
        }
        .onAppear { ringer.start(soundEnabled: true) }
        .onDisappear { ringer.stop() }
    }

    private func incomingAction(title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 66, height: 66)
                    .background(color, in: Circle())
                    .shadow(color: color.opacity(0.28), radius: 14, y: 8)
                Text(title).font(.caption).foregroundStyle(palette.text)
            }
        }
        .buttonStyle(.plain)
    }
}

@MainActor
private final class IncomingCallRinger: ObservableObject {
    @Published var pulse = false
    private var timer: Timer?

    func start(soundEnabled: Bool) {
        withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) { pulse = true }
        setSoundEnabled(soundEnabled)
    }

    func setSoundEnabled(_ enabled: Bool) {
        if !enabled {
            timer?.invalidate()
            timer = nil
            return
        }
        guard timer == nil else { return }
        ring()
        timer = Timer.scheduledTimer(withTimeInterval: 2.2, repeats: true) { _ in
            AudioServicesPlayAlertSound(SystemSoundID(1005))
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        pulse = false
    }

    private func ring() {
        AudioServicesPlayAlertSound(SystemSoundID(1005))
    }
}

private struct ComposerHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 126

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct ComposerView: View {
    @ObservedObject var model: AppModel
    let viewportWidth: CGFloat
    let onShowSessions: () -> Void
    @StateObject private var recorder = VoiceRecorder()
    @StateObject private var kaomojiStore = KaomojiLibraryStore()
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showingAttachmentMenu = false
    @State private var showingKaomojiDrawer = false
    @State private var showingPhotoPicker = false
    @State private var showingCamera = false
    @State private var cameraPermissionDenied = false
    @State private var importingAttachments = false
    @State private var importedTypes: [UTType] = [.item]
    @State private var draftText = ""
    @State private var currentBrain: BrainTarget = .desktop
    @FocusState private var isDraftFocused: Bool

    private var palette: EchoPalette { model.theme.palette }
    private var isNest: Bool { model.theme == .nest }

    var body: some View {
        VStack(spacing: isNest ? 10 : 7) {
            if recorder.isRecording || recorder.hasRecording {
                HStack(spacing: 11) {
                    Button { recorder.cancel() } label: {
                        Image(systemName: "xmark").font(.system(size: 13, weight: .bold))
                    }
                    .foregroundStyle(palette.secondaryText)

                    HStack(alignment: .center, spacing: 3) {
                        ForEach(0..<18, id: \.self) { index in
                            Capsule()
                                .fill(palette.accent.opacity(0.45 + min(0.5, recorder.level)))
                                .frame(width: 2.5, height: CGFloat(7 + ((index * 5) % 13)) * (0.55 + recorder.level * 0.7))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Text(formatVoiceTime(recorder.duration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(palette.secondaryText)

                    Button {
                        sendVoice()
                    } label: {
                        if model.isUploadingVoice {
                            ProgressView().controlSize(.small).tint(.white)
                        } else {
                            Label(recorder.isRecording ? "发送" : "发出", systemImage: "arrow.up")
                                .font(.caption.weight(.bold))
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(palette.accent, in: Capsule())
                    .disabled(model.isUploadingVoice)
                }
                .padding(.horizontal, usesTelegramComposer ? 12 : 2)
                .padding(.vertical, 6)
                .background {
                    // The Telegram bar has no dock behind it, so the recording strip brings its own glass.
                    if usesTelegramComposer {
                        Color.clear.glassEffect(.regular, in: Capsule())
                    }
                }
            }

            if !model.pendingAttachments.isEmpty || model.isUploading {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.pendingAttachments) { attachment in
                            HStack(spacing: 7) {
                                Image(systemName: attachmentIcon(attachment))
                                Text(attachment.name).lineLimit(1)
                                Button { model.removePendingAttachment(attachment) } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(palette.text)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(palette.aiBubble, in: Capsule())
                        }
                        if model.isUploading { ProgressView().tint(palette.accent) }
                    }
                    .padding(.horizontal, 2)
                }
            }

            if usesTelegramComposer {
                telegramComposer
            } else if usesWeChatComposer {
                weChatComposer
            } else if usesIMessageLayout {
                if !model.bundledMessageParts.isEmpty {
                    Button { Task { await model.sendBundledMessages() } } label: {
                        Label("让 AI 回复这 \(model.bundledMessageParts.count) 条", systemImage: "paperplane")
                            .font(.footnote)
                            .foregroundStyle(palette.text)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.regularMaterial, in: Capsule())
                    }
                    .disabled(model.isSendingBundledMessage || model.hasPendingBundledMessageUploads)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                iMessageComposer
            } else {
                TextField(isNest ? "" : "和Altair说话…", text: $draftText, axis: .vertical)
                    .lineLimit(1...(isNest ? 4 : 5))
                    .font(model.chatFont.font(
                        size: PWAChatMetrics.composerFontSize(for: model.chatFont) * model.fontScale,
                        numericWeight: model.chatWeight
                    ))
                    .foregroundStyle(palette.text)
                    .overlay(alignment: .topLeading) {
                        // ChatNest writes its prompt in the UI sans, never the serif body face.
                        if isNest && draftText.isEmpty {
                            Text("Reply to Claude")
                                .font(.system(size: 16 * model.fontScale, weight: .regular))
                                .foregroundStyle(palette.secondaryText.opacity(0.8))
                                .allowsHitTesting(false)
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, isNest ? 1 : 3)
                    .padding(.bottom, isNest ? 0 : 2)
                    .focused($isDraftFocused)

                HStack(alignment: .center, spacing: isNest ? 6 : 7) {
                    Button { showingAttachmentMenu = true } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(composerAuxiliaryForeground)
                            .frame(width: isNest ? 32 : 35, height: isNest ? 32 : 35)
                            .background { composerAuxiliaryChrome(Circle()) }
                    }
                    .disabled(model.isUploading)

                    Button { showingKaomojiDrawer = true } label: {
                        Image(systemName: "face.smiling")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(composerAuxiliaryForeground)
                            .frame(width: isNest ? 32 : 35, height: isNest ? 32 : 35)
                            .background { composerAuxiliaryChrome(Circle()) }
                    }
                    .accessibilityLabel("打开颜文字抽屉")

                    Button(action: onShowSessions) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(model.isStreamConnected ? Color.green.opacity(0.86) : palette.secondaryText.opacity(0.72))
                                .frame(width: 6, height: 6)
                            Text(brainLabel)
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.9)
                                .layoutPriority(1)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(palette.secondaryText)
                        }
                        .foregroundStyle(palette.text)
                        .padding(.horizontal, isNest ? 11 : 10)
                        .frame(height: isNest ? 32 : 35)
                        .background { composerAuxiliaryChrome(Capsule(), opacity: 0.86) }
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .layoutPriority(1)
                    .accessibilityLabel(
                        "对话窗口，当前身体 \(brainLabel)，\(model.isStreamConnected ? "在线" : "离线")"
                    )

                    Spacer(minLength: 0)

                    Button {
                        toggleRecording()
                    } label: {
                        Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(recorder.isRecording ? Color.white : composerAuxiliaryForeground)
                            .frame(width: isNest ? 32 : 35, height: isNest ? 32 : 35)
                            .background {
                                if recorder.isRecording {
                                    Circle().fill(Color.red.opacity(0.82))
                                } else {
                                    composerAuxiliaryChrome(Circle())
                                }
                            }
                    }
                    .disabled(model.isUploadingVoice)

                    Button {
                        send()
                    } label: {
                        Group {
                            if model.isSendingBundledMessage {
                                ProgressView().controlSize(.small).tint(composerSendForeground)
                            } else {
                                Image(systemName: sendButtonIcon)
                                    .font(.system(size: isNest ? 17 : 16, weight: isNest ? .semibold : .bold))
                            }
                        }
                        .foregroundStyle(composerSendForeground.opacity(canSend ? 1 : 0.72))
                        .frame(width: isNest ? 33 : 36, height: isNest ? 33 : 36)
                        .background(composerSendBackground.opacity(canSend ? 1 : 0.34), in: Circle())
                    }
                    .disabled(!canSend)
                    .accessibilityLabel(sendButtonAccessibilityLabel)
                    .accessibilityHint(sendButtonAccessibilityHint)
                }
            }
        }
        .padding(.horizontal, usesTelegramComposer ? 0 : (usesWeChatComposer ? 10 : (usesIMessageLayout ? 0 : (isNest ? 13 : 10))))
        .padding(.vertical, usesTelegramComposer ? 0 : (usesWeChatComposer ? 8 : (usesIMessageLayout ? 0 : (isNest ? 13 : 10))))
        .background {
            if usesTelegramComposer {
                // Floats on the wallpaper: each control carries its own glass.
                EmptyView()
            } else if usesWeChatComposer {
                weChatDockBackground
            } else if !usesIMessageLayout {
                composerContainerGlass
            }
        }
        .padding(.horizontal, usesTelegramComposer
            ? telegramSideInset
            : (usesWeChatComposer ? 0 : (usesIMessageLayout ? iMessageMetrics.composerInset : (isNest ? 14 : 12))))
        .padding(.top, usesTelegramComposer ? 6 : (usesWeChatComposer ? 0 : (usesIMessageLayout ? 6 : (isNest ? 4 : 7))))
        .padding(.bottom, usesTelegramComposer ? (isDraftFocused ? 8 : 0) : (usesWeChatComposer ? 0 : (usesIMessageLayout ? 4 : (isNest ? 5 : 7))))
        // Telegram sits a little into the home-indicator area while the keyboard is down.
        .offset(y: usesTelegramComposer && !isDraftFocused ? 5 : 0)
        .animation(.spring(response: 0.36, dampingFraction: 0.86), value: usesTelegramComposer && isDraftFocused)
        .task { await loadBrain() }
        .onDisappear { recorder.cancel() }
        .onChange(of: photoItems) { items in
            guard !items.isEmpty else { return }
            photoItems = []
            Task { await uploadPhotos(items) }
        }
        .confirmationDialog("添加附件", isPresented: $showingAttachmentMenu, titleVisibility: .visible) {
            Button("相机") { presentCamera() }
            Button("照片") { presentPhotoPicker() }
            Button("文件") { presentFileImporter(types: [.item]) }
            Button("音乐") { presentFileImporter(types: [.audio]) }
            Button("取消", role: .cancel) {}
        }
        .sheet(isPresented: $showingKaomojiDrawer) {
            KaomojiDrawer(
                store: kaomojiStore,
                title: "颜文字",
                style: kaomojiStyle
            ) { face in
                draftText += face
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.hidden)
            .presentationCornerRadius(28)
        }
        .photosPicker(
            isPresented: $showingPhotoPicker,
            selection: $photoItems,
            maxSelectionCount: 9,
            matching: .images
        )
        .fullScreenCover(isPresented: $showingCamera) {
            CameraCaptureView(
                onCapture: { image in
                    showingCamera = false
                    uploadCapturedPhoto(image)
                },
                onCancel: { showingCamera = false }
            )
            .ignoresSafeArea()
        }
        .fileImporter(
            isPresented: $importingAttachments,
            allowedContentTypes: importedTypes,
            allowsMultipleSelection: true
        ) { result in
            importURLs(result)
        }
        .alert("无法使用相机", isPresented: $cameraPermissionDenied) {
            Button("打开系统设置") {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("请在系统设置中允许 Tidal Echo 使用相机。")
        }
    }

    private var usesIMessageLayout: Bool { model.chatLayoutStyle == .imessage }

    private var usesWeChatComposer: Bool { model.composerStyle == .wechat }
    private var usesTelegramComposer: Bool { model.composerStyle == .telegram }

    /// Telegram tucks the bar in toward the screen's rounded corners while the
    /// keyboard is down (26pt on a 390pt-wide phone) and widens it to 8pt above the keyboard.
    private var telegramSideInset: CGFloat {
        isDraftFocused ? 8 : min(26, max(12, viewportWidth / 15))
    }

    private var telegramComposer: some View {
        TelegramComposerBar(
            text: $draftText, focus: $isDraftFocused,
            palette: palette,
            font: model.chatFont.font(size: 17 * model.fontScale, numericWeight: model.chatWeight),
            isOnline: model.isStreamConnected, sessionLabel: brainLabel,
            uploading: model.isUploading,
            isRecording: recorder.isRecording, voiceDisabled: model.isUploadingVoice,
            isSending: model.isSendingBundledMessage,
            showsSend: canSend || model.isSendingBundledMessage,
            sendIcon: sendButtonIcon,
            sendLabel: sendButtonAccessibilityLabel, sendHint: sendButtonAccessibilityHint,
            onAttachments: {
                isDraftFocused = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    showingAttachmentMenu = true
                }
            },
            onFaces: {
                isDraftFocused = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    showingKaomojiDrawer = true
                }
            },
            onSessions: onShowSessions,
            onVoice: { toggleRecording() },
            onSend: { send() }
        )
    }

    private var weChatComposer: some View {
        WeChatComposerBar(
            text: $draftText, focus: $isDraftFocused,
            palette: palette,
            font: model.chatFont.font(size: 15 * model.fontScale, numericWeight: model.chatWeight),
            isDark: model.theme == .harbor,
            isOnline: model.isStreamConnected, sessionLabel: brainLabel,
            uploading: model.isUploading,
            isRecording: recorder.isRecording, voiceDisabled: model.isUploadingVoice,
            isSending: model.isSendingBundledMessage, canSend: canSend,
            sendIcon: sendButtonIcon,
            sendLabel: sendButtonAccessibilityLabel, sendHint: sendButtonAccessibilityHint,
            onAttachments: {
                isDraftFocused = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    showingAttachmentMenu = true
                }
            },
            onFaces: {
                isDraftFocused = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    showingKaomojiDrawer = true
                }
            },
            onSessions: onShowSessions,
            onVoice: { toggleRecording() },
            onSend: { send() }
        )
    }

    private var weChatDockBackground: some View {
        let isDark = model.theme == .harbor
        // 原来是磨砂上盖一层均匀主题色，没有明暗，像一块亚克力板。
        // 改成上亮下沉的一层薄光，再给上沿一道受光的边，磨砂才有厚度。
        return Rectangle()
            .fill(.ultraThinMaterial)
            .overlay {
                LinearGradient(
                    colors: [
                        Color.white.opacity(isDark ? 0.05 : 0.20),
                        palette.composer.opacity(isDark ? 0.06 : 0.12)
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            }
            .overlay(alignment: .top) {
                VStack(spacing: 0) {
                    Rectangle().fill(palette.hairline.opacity(isDark ? 1 : 0.7)).frame(height: 0.5)
                    LinearGradient(
                        colors: [
                            Color.white.opacity(isDark ? 0.02 : 0.20),
                            Color.white.opacity(isDark ? 0.16 : 0.80),
                            Color.white.opacity(isDark ? 0.02 : 0.20)
                        ],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(height: 0.5)
                }
            }
            .shadow(color: Color.black.opacity(isDark ? 0.22 : 0.045), radius: 12, y: -2)
            // Extend only the material through the home-indicator safe area.
            // Content keeps the keyboard-safe layout and adds no blank spacer.
            .ignoresSafeArea(.container, edges: .bottom)
            .allowsHitTesting(false)
    }

    private var iMessageMetrics: IMessageLayoutMetrics {
        IMessageLayoutMetrics(viewportWidth: viewportWidth)
    }

    private var iMessageAction: IMessageComposerAction {
        IMessageComposerAction(
            hasContent: hasCurrentComposerContent,
            isRecording: recorder.isRecording,
            isSending: model.isSendingBundledMessage
        )
    }

    private var iMessageComposer: some View {
        IMessageComposerBar(
            text: $draftText, focus: $isDraftFocused,
            metrics: iMessageMetrics, palette: palette,
            font: model.chatFont.font(
                size: Double(iMessageMetrics.composerFontSize) * model.fontScale,
                numericWeight: model.chatWeight
            ),
            action: iMessageAction,
            actionDisabled: model.isSendingBundledMessage || model.isUploadingVoice,
            sendLabel: sendButtonAccessibilityLabel,
            sendHint: sendButtonAccessibilityHint,
            uploading: model.isUploading,
            onAttachments: {
                isDraftFocused = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    showingAttachmentMenu = true
                }
            },
            onFaces: {
                isDraftFocused = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    showingKaomojiDrawer = true
                }
            },
            onAction: {
                switch iMessageAction {
                case .send: send()
                case .voice, .stopRecording:
                    isDraftFocused = false
                    toggleRecording()
                case .sending: break
                }
            }
        )
    }

    @ViewBuilder
    private var composerContainerGlass: some View {
        let shape = RoundedRectangle(cornerRadius: isNest ? 24 : 29, style: .continuous)
        if isNest {
            shape
                .fill(Color.white.opacity(0.001))
                .glassEffect(.clear.tint(palette.composer), in: shape)
                .overlay(shape.fill(Color.white.opacity(0.34)))
                .overlay(shape.stroke(Color.white.opacity(0.72), lineWidth: 0.7))
                .overlay(shape.stroke(palette.hairline, lineWidth: 0.45))
                .shadow(color: Color.black.opacity(0.075), radius: 16, y: 6)
        } else if model.theme == .harbor {
            shape
                .fill(Color.black.opacity(0.06))
                .glassEffect(.clear.tint(palette.composer.opacity(0.14)), in: shape)
                .overlay(shape.fill(palette.composer.opacity(0.12)))
                .overlay(shape.stroke(Color.white.opacity(0.18), lineWidth: 0.7))
                .overlay(shape.stroke(palette.hairline, lineWidth: 0.45))
                .shadow(color: Color.black.opacity(0.16), radius: 12, y: 4)
        } else {
            shape
                .fill(.ultraThinMaterial)
                .overlay(shape.fill(palette.composer.opacity(model.theme == .paper ? 0.58 : 0.42)))
                .overlay(shape.stroke(Color.white.opacity(model.theme == .harbor ? 0.13 : 0.42), lineWidth: 0.7))
                .overlay(shape.stroke(palette.hairline, lineWidth: 0.5))
                .shadow(color: Color.black.opacity(0.08), radius: 14, y: 5)
        }
    }

    private var kaomojiStyle: KaomojiDrawerStyle {
        KaomojiDrawerStyle(
            backgroundTop: palette.backgroundTop,
            backgroundBottom: palette.backgroundBottom,
            glow: palette.accent,
            card: palette.aiBubble,
            accent: palette.accent,
            text: palette.text,
            secondaryText: palette.secondaryText
        )
    }

    private var composerAuxiliaryBackground: Color {
        if isNest { return Color(hex: 0xF5F5F2) }
        return model.theme == .paper ? Color(hex: 0xF0EEE6) : palette.aiBubble
    }

    private var composerAuxiliaryForeground: Color {
        if isNest { return Color(hex: 0x292826) }
        if model.theme == .harbor { return Color.white.opacity(0.90) }
        return model.theme == .paper ? Color(hex: 0x2B2A27) : palette.accent
    }

    @ViewBuilder
    private func composerAuxiliaryChrome<S: Shape>(
        _ shape: S,
        opacity: Double = 1
    ) -> some View {
        if model.theme == .harbor {
            shape
                .fill(.ultraThinMaterial)
                .overlay {
                    shape.fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.10 * opacity),
                                Color.white.opacity(0.035 * opacity)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                }
                .overlay {
                    shape.stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.24 * opacity),
                                Color.white.opacity(0.07 * opacity)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.65
                    )
                }
                .shadow(color: Color.black.opacity(0.12 * opacity), radius: 5, y: 2)
        } else {
            shape.fill(composerAuxiliaryBackground.opacity(opacity))
        }
    }

    private var composerSendBackground: Color {
        if isNest { return Color(hex: 0x171716) }
        return model.theme == .paper ? Color(hex: 0x2B2A27) : palette.accent
    }

    private var composerSendForeground: Color {
        model.theme == .harbor ? palette.onAccent : Color.white
    }

    private func loadBrain() async {
        do { currentBrain = try await model.settingsBrain() }
        catch { /* Keep the last known label while the relay reconnects. */ }
    }

    /// Keep the fixed body labels for Claude Code / Codex, but let each API
    /// window carry the custom title she gave that conversation.
    private var brainLabel: String {
        if model.activeSessionID == AppModel.legacySessionID { return "Claude Code" }
        if let session = model.sessions.first(where: { $0.id == model.activeSessionID }) {
            switch session.body {
            case .desktop:
                return "Claude Code"
            case .codex:
                return "Codex"
            case .loop:
                let customTitle = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
                return customTitle.isEmpty ? "API" : customTitle
            }
        }
        return currentBrain == .desktop ? "Claude Code" : currentBrain.title
    }

    private var canSend: Bool {
        guard !model.isSendingBundledMessage else { return false }
        if hasCurrentComposerContent { return true }
        return !model.bundledMessageParts.isEmpty && !model.hasPendingBundledMessageUploads
    }

    private var hasCurrentComposerContent: Bool {
        !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !model.pendingAttachments.isEmpty
    }

    private var sendButtonIcon: String {
        if !hasCurrentComposerContent && !model.bundledMessageParts.isEmpty { return "paperplane.fill" }
        if model.aiReplyTiming == .bundled { return "tray.full.fill" }
        if usesTelegramComposer { return "paperplane.fill" }
        return isNest && !usesWeChatComposer ? "waveform" : "arrow.up"
    }

    private var sendButtonAccessibilityLabel: String {
        if !hasCurrentComposerContent && !model.bundledMessageParts.isEmpty {
            return "让 AI 统一回复上面的 \(model.bundledMessageParts.count) 条消息"
        }
        return model.aiReplyTiming == .bundled ? "发送消息，稍后统一回复" : "发送消息"
    }

    private var sendButtonAccessibilityHint: String {
        if model.aiReplyTiming == .bundled && hasCurrentComposerContent {
            return "消息会立刻显示在聊天页，AI 暂时不会回复"
        }
        return "AI 会收到消息"
    }

    private func presentPhotoPicker() {
        // Let the confirmation dialog finish dismissing before presenting a
        // second system controller. Presenting both in the same run-loop turn
        // is silently ignored on some iOS 16/17 builds.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            showingPhotoPicker = true
        }
    }

    private func presentCamera() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
                model.errorMessage = "这台设备当前没有可用的相机。"
                return
            }
            Task {
                let status = AVCaptureDevice.authorizationStatus(for: .video)
                let allowed: Bool
                if status == .authorized {
                    allowed = true
                } else if status == .notDetermined {
                    allowed = await AVCaptureDevice.requestAccess(for: .video)
                } else {
                    allowed = false
                }
                if allowed {
                    showingCamera = true
                } else {
                    cameraPermissionDenied = true
                }
            }
        }
    }

    private func presentFileImporter(types: [UTType]) {
        importedTypes = types
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            importingAttachments = true
        }
    }

    private func attachmentIcon(_ attachment: Attachment) -> String {
        if attachment.isImage { return "photo" }
        if attachment.isAudio { return "music.note" }
        return "doc"
    }

    private func uploadPhotos(_ items: [PhotosPickerItem]) async {
        for item in items.prefix(9) {
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                model.errorMessage = "有一张图片没有读出来"
                continue
            }
            let type = item.supportedContentTypes.first ?? .jpeg
            let ext = type.preferredFilenameExtension ?? "jpg"
            await model.uploadAttachment(
                data: data,
                name: "photo-\(UUID().uuidString.prefix(8)).\(ext)",
                mime: type.preferredMIMEType ?? "image/jpeg"
            )
        }
    }

    private func uploadCapturedPhoto(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.9) else {
            model.errorMessage = "刚拍的照片没有保存成功。"
            return
        }
        Task {
            await model.uploadAttachment(
                data: data,
                name: "camera-\(UUID().uuidString.prefix(8)).jpg",
                mime: "image/jpeg"
            )
        }
    }

    private func importURLs(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            model.errorMessage = "没有读到附件：\(error.localizedDescription)"
        case .success(let urls):
            Task {
                for url in urls.prefix(9) {
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                    do {
                        let values = try url.resourceValues(forKeys: [.contentTypeKey])
                        let data = try Data(contentsOf: url, options: .mappedIfSafe)
                        await model.uploadAttachment(
                            data: data,
                            name: url.lastPathComponent,
                            mime: values.contentType?.preferredMIMEType ?? "application/octet-stream"
                        )
                    } catch {
                        model.errorMessage = "附件读取失败：\(url.lastPathComponent)"
                    }
                }
            }
        }
    }

    private func send() {
        guard canSend else { return }
        if hasCurrentComposerContent {
            let text = draftText
            draftText = ""
            if model.aiReplyTiming == .bundled {
                Task { await model.stageBundledMessage(text: text) }
            } else {
                Task { await model.sendMessage(text: text) }
            }
            isDraftFocused = true
        } else {
            Task { await model.sendBundledMessages() }
        }
    }

    private func toggleRecording() {
        if recorder.isRecording {
            recorder.finish()
        } else {
            recorder.cancel()
            Task {
                do { try await recorder.start() }
                catch { model.errorMessage = error.localizedDescription }
            }
        }
    }

    private func sendVoice() {
        if recorder.isRecording { recorder.finish() }
        Task {
            do {
                let result = try recorder.result()
                if await model.sendVoiceRecording(result) { recorder.markSent() }
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
    }

    private func formatVoiceTime(_ value: TimeInterval) -> String {
        let total = max(0, Int(value))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
