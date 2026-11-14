extends Control
## Online client for JokerShift. Never calculates deck, legality or opponent's hidden cards.
## Server must be running independently (see online/server/README_RU.md).

const CONFIG_PATH: String = "user://jokershift_online.cfg"
const SERVER_URL_CONFIG: String = "res://online/connection.json"
const FACE_PATH: String = "res://assets/faces/"
const WHITE: Color = Color("#F1E4FF")
const PURPLE: Color = Color("#AD72FF")
const INK: Color = Color("#1B102A")

var offline_game: Control
var socket: WebSocketPeer
var pending_request: Dictionary = {}
var connected: bool = false
var connection_time: int = 0
var state: Dictionary = {}
var your_seat: int = -1
var selected_card_id: int = -1
var current_code: String = ""
var room_ready: bool = false
var quick_searching: bool = false
var quick_match_room: bool = false
var quick_search_cancelled: bool = false
var quick_cancel_pending: bool = false
var logged_in: bool = false
var player_id: String = ""
var saved_token: String = ""
var profile_storage_path: String = CONFIG_PATH
var friends_state: Dictionary = {}
var chat_history: Dictionary = {}
var chat_target_id: String = "" # empty = room chat
var invitation_code: String = ""
var friends_section: VBoxContainer
var friend_server_input: LineEdit
var connection_panel: VBoxContainer
var retries_remaining: int = 0
var retry_due_ms: int = 0
var connecting_sleep_server: bool = false
var room_chat_button: Button
var page: String = "online"
var pending_invite_friend_id: String = ""
var section_title: Label
var social_body: VBoxContainer
var social_id_label: Label
var social_friend_id: LineEdit
var friends_container: VBoxContainer
var requests_container: VBoxContainer
var sent_container: VBoxContainer
var chat_dialog: AcceptDialog
var chat_title: Label
var chat_log: TextEdit
var chat_input: LineEdit
var invite_dialog: ConfirmationDialog


var root: VBoxContainer
var form_panel: PanelContainer
var waiting_panel: VBoxContainer
var game_panel: VBoxContainer
var url_input: LineEdit
var code_input: LineEdit
var status_label: Label
var room_label: Label
var ready_label: Label
var ready_button: Button
var waiting_title: Label
var copy_room_button: Button
var cancel_quick_button: Button
var header: Label
var enemy_row: Control
var enemy_caption: Label
var table_grid: GridContainer
var hand_row: Control
var hand_scroll: ScrollContainer
var online_scroll: ScrollContainer
var online_content_margin: MarginContainer
var online_top_table_spacer: Control
var online_hand_bottom_spacer: Control
var online_table_frame: PanelContainer
var online_trump_caption: Label
var online_player_caption: Label
var online_game_notice: Label
var online_table_caption: Label
var online_actions_dock: PanelContainer
var online_actions_grid: GridContainer
var online_hand_layout_queued: bool = false
var online_enemy_layout_queued: bool = false
var my_turn_label: Label
var deck_label: Label
var action_finish: Button
var action_take: Button
var take_request_pending: bool = false
var action_draw: Button
var highlighted_online_action: String = ""
var joker_dialog: AcceptDialog
var joker_choices: VBoxContainer
var pending_joker_verb: String = ""
var pending_pair_index: int = -1


func _ready() -> void:
	name = "OnlineJokerShift"
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build()
	set_process(true)


func _process(_delta: float) -> void:
	if socket == null:
		if retry_due_ms > 0 and Time.get_ticks_msec() >= retry_due_ms:
			retry_due_ms = 0
			_open_socket()
		return
	socket.poll()
	var status: int = socket.get_ready_state()
	if status == WebSocketPeer.STATE_OPEN:
		if not connected:
			connected = true
			retries_remaining = 0
			connecting_sleep_server = false
			_info("Подключено. Загружаем профиль...")
			_send({"type": "hello", "name": _player_name(), "token": saved_token})
		while socket.get_available_packet_count() > 0:
			var data: PackedByteArray = socket.get_packet()
			if not socket.was_string_packet():
				continue
			var parsed: Variant = JSON.parse_string(data.get_string_from_utf8())
			if parsed is Dictionary:
				_on_packet(parsed)
	elif status == WebSocketPeer.STATE_CLOSED:
		if not connected and retries_remaining > 0:
			_retry_socket()
		elif connected or not pending_request.is_empty() or connecting_sleep_server:
			_info("Нет соединения. Проверь интернет или сервер.")
			_reset_connection()
	elif status == WebSocketPeer.STATE_CONNECTING:
		if Time.get_ticks_msec() - connection_time > 14000:
			if retries_remaining > 0:
				_retry_socket()
			else:
				_info("Сервер не отвечает. Проверь соединение.")
				_reset_connection()


func _reset_connection() -> void:
	if socket != null:
		if socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
			socket.close(1000, "Leaving")
		socket = null
	connected = false
	take_request_pending = false
	retries_remaining = 0
	retry_due_ms = 0
	connecting_sleep_server = false
	pending_request.clear()
	current_code = ""
	your_seat = -1
	state.clear()
	selected_card_id = -1
	room_ready = false
	quick_searching = false
	quick_match_room = false
	quick_search_cancelled = false
	quick_cancel_pending = false
	logged_in = false
	player_id = ""
	pending_invite_friend_id = ""
	friends_state.clear()
	if friends_container != null:
		_render_social()
	if chat_dialog != null:
		chat_dialog.hide()
	form_panel.visible = page == "online"
	waiting_panel.hide()
	if cancel_quick_button != null:
		cancel_quick_button.hide()
	game_panel.hide()
	_sync_online_action_dock()
	if room_chat_button != null:
		room_chat_button.hide()


func _info(message: String) -> void:
	if status_label != null:
		status_label.text = message
	if online_game_notice != null:
		online_game_notice.text = message


func _send(packet: Dictionary) -> void:
	if socket != null and socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		socket.send_text(JSON.stringify(packet))


func _player_name() -> String:
	if offline_game == null:
		return "Игрок"
	if offline_game.nick_input != null:
		var value: String = offline_game.nick_input.text.strip_edges()
		if not value.is_empty():
			offline_game.player_nick = value
			offline_game.save_profile()
			return value
	return str(offline_game.player_nick)


func _sound(kind: String) -> void:
	if offline_game != null and is_instance_valid(offline_game):
		offline_game.play_sfx(kind)


func _configured_url() -> String:
	var config: ConfigFile = ConfigFile.new()
	if config.load(profile_storage_path) == OK:
		var local: String = str(config.get_value("connection", "url", "")).strip_edges()
		if not local.is_empty():
			return local
	if FileAccess.file_exists(SERVER_URL_CONFIG):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(SERVER_URL_CONFIG))
		if parsed is Dictionary:
			return str(parsed.get("server_url", "")).strip_edges()
	return ""


func _open_socket() -> void:
	socket = WebSocketPeer.new()
	connection_time = Time.get_ticks_msec()
	var err: Error = socket.connect_to_url(url_input.text.strip_edges())
	if err != OK:
		socket = null
		if retries_remaining > 0:
			_retry_socket()
		else:
			_info("Не удалось подключиться к серверу (%d)." % err)
			_reset_connection()
		return
	_info("Подключаемся к общему серверу...")


func _retry_socket() -> void:
	socket = null
	connected = false
	retries_remaining -= 1
	connecting_sleep_server = true
	retry_due_ms = Time.get_ticks_msec() + 5000
	_info("Сервер просыпается… подключаемся автоматически (%d)." % (retries_remaining + 1))


func _toggle_connection() -> void:
	connection_panel.visible = not connection_panel.visible
	if connection_panel.visible:
		url_input.grab_focus()


func _save_server_url() -> void:
	var url: String = url_input.text.strip_edges().trim_suffix("/")
	if not url.begins_with("ws://") and not url.begins_with("wss://"):
		_info("Адрес должен начинаться с wss://")
		return
	url_input.text = url
	var cfg: ConfigFile = ConfigFile.new()
	cfg.load(profile_storage_path)
	cfg.set_value("connection", "url", url)
	cfg.save(profile_storage_path)
	connection_panel.hide()
	if socket != null:
		_reset_connection()
	_info("Адрес сохранён. В следующий раз вводить его не нужно.")


func _begin_request(kind: String) -> void:
	var url: String = url_input.text.strip_edges()
	if url.is_empty():
		url = _configured_url()
		url_input.text = url
	if not url.begins_with("ws://") and not url.begins_with("wss://"):
		connection_panel.show()
		_info("Сервер пока не настроен. Один раз вставь адрес Render.")
		return
	if kind == "join":
		var code: String = code_input.text.strip_edges()
		if code.length() != 6 or not code.is_valid_int():
			_info("Код комнаты — 6 цифр.")
			return
	if kind != "login" and not current_code.is_empty():
		_info("Сначала покинь текущую комнату.")
		return
	if kind != "login" and quick_cancel_pending:
		_info("Дожидаемся подтверждения отмены предыдущего поиска.")
		return
	if kind != "login" and quick_searching:
		_info("Ты уже ищешь соперника. Сначала отмени поиск.")
		return
	if kind == "quick_match":
		quick_searching = true
		quick_match_room = false
		quick_search_cancelled = false
		form_panel.hide()
		waiting_panel.show()
		waiting_title.text = "ПОИСК СЛУЧАЙНОГО СОПЕРНИКА"
		ready_label.text = "Ищем игрока на общем сервере..."
		ready_button.hide()
		copy_room_button.hide()
		cancel_quick_button.show()
		room_label.text = "БЫСТРАЯ ИГРА"
		_info("Поиск игрока. Можно отменить в любой момент.")
	if kind != "login":
		pending_request = {"type": kind, "name": _player_name()}
		if kind == "join":
			pending_request["code"] = code_input.text.strip_edges()
	if connected and logged_in:
		if not pending_request.is_empty():
			_send(pending_request)
			pending_request.clear()
		else:
			_info("Профиль уже подключён.")
		return
	if socket != null:
		_info("Подключаемся…")
		return
	var cfg: ConfigFile = ConfigFile.new()
	if cfg.load(profile_storage_path) == OK:
		saved_token = str(cfg.get_value("account", "token", ""))
	retries_remaining = 8
	retry_due_ms = 0
	connecting_sleep_server = false
	_open_socket()


func _copy_room_code() -> void:
	if current_code.is_empty():
		return
	DisplayServer.clipboard_set(current_code)
	_info("Код %s скопирован. Отправь другу." % current_code)


func _on_packet(packet: Dictionary) -> void:
	match str(packet.get("type", "")):
		"error":
			take_request_pending = false
			if quick_searching and current_code.is_empty():
				quick_searching = false
				waiting_panel.hide()
				form_panel.visible = page == "online"
				cancel_quick_button.hide()
			_info(str(packet.get("message", "Ошибка сервера.")))
		"matchmaking":
			var queue_status: String = str(packet.get("status", ""))
			if queue_status == "waiting" and quick_searching and not quick_search_cancelled:
				form_panel.hide()
				waiting_panel.show()
				waiting_title.text = "ПОИСК СЛУЧАЙНОГО СОПЕРНИКА"
				ready_label.text = "Ищем второго игрока..."
				cancel_quick_button.show()
				copy_room_button.hide()
				ready_button.hide()
				_info("Ожидание свободного игрока...")
			elif queue_status == "cancelled" and current_code.is_empty():
				quick_cancel_pending = false
				quick_searching = false
				waiting_panel.hide()
				cancel_quick_button.hide()
				form_panel.visible = page == "online"
				_info("Поиск отменён.")
		"peer_left":
			current_code = ""
			quick_searching = false
			quick_match_room = false
			state.clear()
			form_panel.visible = page == "online"
			waiting_panel.hide()
			game_panel.hide()
			_sync_online_action_dock()
			room_chat_button.hide()
			room_label.text = "ОНЛАЙН · КОМНАТА"
			_info(str(packet.get("message", "Соперник вышел.")))
		"hello":
			logged_in = true
			player_id = str(packet.get("id", ""))
			saved_token = str(packet.get("token", ""))
			var cfg: ConfigFile = ConfigFile.new()
			cfg.load(profile_storage_path)
			cfg.set_value("account", "token", saved_token)
			cfg.set_value("connection", "url", url_input.text.strip_edges())
			cfg.save(profile_storage_path)
			_render_social()
			_info("Профиль подключён · твой ID: " + player_id)
			if not pending_request.is_empty():
				_send(pending_request)
				pending_request.clear()
		"social":
			friends_state = packet
			_render_social()
		"notice":
			_info(str(packet.get("message", "Готово.")))
		"invite":
			_sound("invite")
			if chat_dialog != null:
				chat_dialog.hide()
			invitation_code = str(packet.get("code", ""))
			invite_dialog.dialog_text = "%s приглашает тебя в комнату %s. Присоединиться?" % [str(packet.get("from_name", "Друг")), invitation_code]
			if not visible and offline_game != null and offline_game.menu_screen.visible:
				show_friends_section()
			if visible:
				invite_dialog.popup_centered(_popup_size(340, 190))
		"dm":
			_sound("message")
			var other: String = str(packet.get("from_id", ""))
			if other == player_id:
				other = str(packet.get("to_id", ""))
			_append_chat("dm:" + other, str(packet.get("from_name", "Друг")), str(packet.get("text", "")))
			if other != player_id and (not chat_dialog.visible or chat_target_id != other):
				_info("✉ Новое сообщение от %s" % str(packet.get("from_name", "Друга")))
		"room_chat":
			_sound("message")
			_append_chat("room:" + current_code, str(packet.get("from_name", "Друг")), str(packet.get("text", "")))
		"room":
			var is_quick_room: bool = str(packet.get("mode", "code")) == "quick"
			if is_quick_room and quick_search_cancelled:
				_send({"type": "leave"})
				return
			_sound("invite")
			quick_match_room = is_quick_room
			quick_searching = false
			current_code = str(packet.get("code", ""))
			show_online_section()
			your_seat = int(packet.get("seat", -1))
			var players: Array = packet.get("players", [])
			var ready: Array = packet.get("ready", [])
			room_ready = ready.has(your_seat)
			form_panel.hide()
			room_label.text = "БЫСТРАЯ ИГРА" if quick_match_room else "КОМНАТА: " + current_code
			waiting_title.text = "СОПЕРНИК НАЙДЕН" if quick_match_room else "ОЖИДАНИЕ ВТОРОГО ИГРОКА"
			copy_room_button.visible = not quick_match_room
			cancel_quick_button.hide()
			ready_button.visible = not quick_match_room
			ready_label.text = "Запускаем матч..." if quick_match_room else ("Игроки: %s / 2\nГотовы: %s / 2" % [players.size(), ready.size()])
			if players.size() == 2:
				ready_label.text += "\n%s против %s" % [str(players[0]), str(players[1])]
			ready_button.disabled = room_ready or players.size() != 2
			ready_button.text = "ЖДЁМ СОПЕРНИКА" if players.size() < 2 else ("ОЖИДАНИЕ..." if room_ready else "Я ГОТОВ")
			waiting_panel.show()
			game_panel.hide()
			room_chat_button.show()
			_render_social()
			if not pending_invite_friend_id.is_empty() and your_seat == 0 and players.size() == 1:
				_send({"type":"invite", "id":pending_invite_friend_id})
				pending_invite_friend_id = ""
			if quick_match_room:
				_info("Соперник найден! Матч запускается автоматически.")
			else:
				_info("Передай другу код %s. Оба нажмите «Готов»." % current_code)
		"state":
			if quick_search_cancelled and current_code.is_empty():
				return
			take_request_pending = false
			var previous_count: int = (state.get("table", []) as Array).size()
			show_online_section()
			state = packet
			if (state.get("table", []) as Array).size() > previous_count:
				_sound("card")
			your_seat = int(state.get("your_seat", -1))
			selected_card_id = -1
			waiting_panel.hide()
			form_panel.hide()
			game_panel.show()
			room_chat_button.show()
			_render_game()
			if str(state.get("stage", "")) == "finished" and offline_game != null:
				var match_id: String = str(state.get("match_id", ""))
				if not match_id.is_empty():
					var seat: int = int(state.get("your_seat", -1))
					var winner: Variant = state.get("winner", null)
					var outcome: String = "draw" if winner == null else ("win" if int(winner) == seat else "loss")
					var scoped_id: String = str(url_input.text.strip_edges()) + ":" + player_id + ":" + match_id
					var reward: int = offline_game.award_match_xp("online", outcome, scoped_id)
					if reward > 0:
						_info("Партия завершена! +%d XP · Уровень %d" % [reward, offline_game.profile_level])
		"pong":
			pass


func _popup_size(w: int, h: int) -> Vector2i:
	var screen: Vector2 = get_viewport_rect().size
	return Vector2i(mini(w, int(screen.x) - 12), mini(h, int(screen.y) - 24))


func _copy_id() -> void:
	DisplayServer.clipboard_set(player_id)
	_info("ID скопирован. Отправь его другу.")


func _add_friend() -> void:
	var friend_id: String = social_friend_id.text.strip_edges()
	if friend_id.length() != 8 or not friend_id.is_valid_int():
		_info("ID друга — 8 цифр.")
		return
	_send({"type":"friend_request", "id":friend_id})


func _social_send(kind: String, uid: String) -> void:
	_send({"type":kind,"id":uid})


func _invite_friend(uid: String) -> void:
	if not logged_in:
		_info("Сначала подключи профиль к серверу.")
		return
	if current_code.is_empty():
		pending_invite_friend_id = uid
		_send({"type":"create", "name":_player_name()})
		_info("Создаём комнату и приглашаем друга...")
	elif your_seat == 0 and waiting_panel.visible:
		_send({"type":"invite", "id":uid})
		_info("Отправляем приглашение другу...")
	else:
		_info("Пригласить друга можно только до начала партии.")


func _accept_invitation() -> void:
	if not current_code.is_empty():
		_info("Сначала выйди из своей комнаты.")
		return
	show_online_section()
	_send({"type":"invite_accept", "code":invitation_code})


func _social_action_button(label_text: String, kind: String, uid: String, parent: Node) -> void:
	var btn: Button = _button(label_text)
	btn.add_theme_font_size_override("font_size", 11)
	btn.pressed.connect(_social_send.bind(kind, uid))
	parent.add_child(btn)


func _render_social() -> void:
	if friends_container == null:
		return
	social_id_label.text = ("ТВОЙ ID: " + player_id + " · можно скопировать" if logged_in else "Подключи профиль, чтобы увидеть свой ID")
	for list_node in [friends_container, requests_container, sent_container]:
		for child in list_node.get_children():
			list_node.remove_child(child)
			child.queue_free()
	var requests: Array = friends_state.get("requests", [])
	if requests.is_empty():
		requests_container.add_child(_label("Нет новых заявок", 12))
	for row in requests:
		var uid: String = str(row.get("id", ""))
		requests_container.add_child(_label(str(row.get("name", "Игрок")) + " · " + uid, 12))
		var actions: HBoxContainer = HBoxContainer.new()
		requests_container.add_child(actions)
		_social_action_button("✓ ПРИНЯТЬ", "friend_accept", uid, actions)
		_social_action_button("ОТКЛОНИТЬ", "friend_decline", uid, actions)
	var sent: Array = friends_state.get("sent", [])
	for row in sent:
		sent_container.add_child(_label("Ожидает: " + str(row.get("name", "Игрок")), 12))
	var friends: Array = friends_state.get("friends", [])
	if friends.is_empty():
		friends_container.add_child(_label("Пока нет друзей. Добавь друга по ID.", 12))
	for friend in friends:
		var uid: String = str(friend.get("id", ""))
		var online: bool = bool(friend.get("online", false))
		friends_container.add_child(_label(("● В СЕТИ  " if online else "○ НЕ В СЕТИ  ") + str(friend.get("name", "Игрок")) + " · " + uid, 12))
		var buttons: GridContainer = GridContainer.new()
		buttons.columns = 2
		buttons.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		buttons.add_theme_constant_override("h_separation", 5)
		buttons.add_theme_constant_override("v_separation", 4)
		friends_container.add_child(buttons)
		var chat_button: Button = _button("✉ ЧАТ")
		chat_button.add_theme_font_size_override("font_size", 11)
		chat_button.disabled = not online
		chat_button.pressed.connect(_open_chat.bind(uid))
		buttons.add_child(chat_button)
		if online and (current_code.is_empty() or (your_seat == 0 and waiting_panel.visible)):
			var invite_button: Button = _button("+ ИГРАТЬ")
			invite_button.add_theme_font_size_override("font_size", 11)
			invite_button.pressed.connect(_invite_friend.bind(uid))
			buttons.add_child(invite_button)
		_social_action_button("УДАЛИТЬ", "friend_remove", uid, buttons)
		_social_action_button("БЛОК", "friend_block", uid, buttons)


func _open_friends() -> void:
	show_friends_section()


func show_friends_section() -> void:
	page = "friends"
	show()
	section_title.text = "✦ JOKERSHIFT · ДРУЗЬЯ ✦"
	room_label.hide()
	form_panel.hide()
	waiting_panel.hide()
	game_panel.hide()
	_sync_online_action_dock()
	room_chat_button.hide()
	friends_section.show()
	if logged_in:
		_send({"type":"social_list"})
	elif socket == null:
		if _configured_url().is_empty():
			_info("Сначала открой «Играть онлайн» и один раз укажи адрес сервера.")
		else:
			_begin_request("login")
	_render_social()


func show_online_section() -> void:
	page = "online"
	show()
	section_title.text = "✦ JOKERSHIFT · ONLINE ✦"
	friends_section.hide()
	room_label.show()
	form_panel.visible = current_code.is_empty() and not quick_searching
	waiting_panel.visible = (quick_searching or not current_code.is_empty()) and state.is_empty()
	game_panel.visible = not current_code.is_empty() and not state.is_empty()
	_sync_online_action_dock()
	room_chat_button.visible = not current_code.is_empty()
	if socket == null and not _configured_url().is_empty():
		_begin_request("login")


func _append_chat(key: String, sender: String, text_value: String) -> void:
	if not chat_history.has(key):
		chat_history[key] = []
	var history: Array = chat_history[key]
	history.append(sender + ": " + text_value)
	if history.size() > 80:
		history.pop_front()
	if chat_dialog.visible:
		var visible_key: String = "room:" + current_code if chat_target_id.is_empty() else "dm:" + chat_target_id
		if key == visible_key:
			_refresh_chat()


func _refresh_chat() -> void:
	var key: String = "room:" + current_code if chat_target_id.is_empty() else "dm:" + chat_target_id
	chat_title.text = "ЧАТ КОМНАТЫ" if chat_target_id.is_empty() else "ЛИЧНЫЙ ЧАТ · " + chat_target_id
	chat_log.text = "\n".join(chat_history.get(key, []))
	chat_log.scroll_vertical = chat_log.get_line_count()


func _open_chat(uid: String = "") -> void:
	chat_target_id = uid
	if uid.is_empty() and current_code.is_empty():
		_info("Создай комнату или открой личный чат с другом.")
		return
	_refresh_chat()
	chat_dialog.popup_centered(_popup_size(400, 480))


func _send_chat() -> void:
	var message: String = chat_input.text.strip_edges()
	if message.is_empty() or message.length() > 240:
		_info("Сообщение должно содержать от 1 до 240 символов.")
		return
	if chat_target_id.is_empty():
		_send({"type":"room_chat", "text":message})
	else:
		_send({"type":"dm", "id":chat_target_id, "text":message})
	chat_input.clear()
	_sound("message")


func _submit_chat(_entered: String) -> void:
	_send_chat()


func _do_ready() -> void:
	_send({"type": "ready"})


func _cancel_quick_search() -> void:
	# A queued request may still be authenticating or connecting.
	if quick_searching and connected:
		quick_cancel_pending = true
		_send({"type": "quick_cancel"})
	elif quick_match_room and connected:
		_send({"type": "leave"})
	pending_request.clear()
	quick_search_cancelled = true
	quick_searching = false
	quick_match_room = false
	current_code = ""
	state.clear()
	waiting_panel.hide()
	game_panel.hide()
	_sync_online_action_dock()
	cancel_quick_button.hide()
	form_panel.visible = page == "online"
	_info("Поиск отменён.")


func _do_leave() -> void:
	# Keep the authenticated WebSocket alive while the user is in the main menu.
	# Otherwise friends would appear offline and invitations could not arrive.
	if not current_code.is_empty():
		_send({"type": "leave"})
	elif quick_searching and connected:
		quick_cancel_pending = true
		_send({"type": "quick_cancel"})
	quick_search_cancelled = true
	quick_searching = false
	quick_match_room = false
	pending_request.clear()
	current_code = ""
	your_seat = -1
	state.clear()
	take_request_pending = false
	room_ready = false
	pending_invite_friend_id = ""
	waiting_panel.hide()
	game_panel.hide()
	_sync_online_action_dock()
	room_chat_button.hide()
	if chat_dialog != null:
		chat_dialog.hide()
	hide()


func _send_action(verb: String, pair_index: int = -1, copy_target: int = -1) -> void:
	# Network response can be delayed: do not queue Take twice while waiting.
	if verb == "take":
		if take_request_pending:
			return
		take_request_pending = true
		if action_take != null:
			action_take.disabled = true
	var action: Dictionary = {"type": "action", "action": verb}
	if selected_card_id >= 0:
		action["card_id"] = selected_card_id
	if pair_index >= 0:
		action["pair_index"] = pair_index
	if copy_target >= 0:
		action["copy_target"] = copy_target
	_send(action)


# Hand order affects only presentation. The card ID stays authoritative.
func _online_is_trump(card: Dictionary) -> bool:
	var suit: String = str(card.get("suit", ""))
	var mode: String = str(state.get("trump_mode", "none"))
	if mode == "red":
		return suit == "♥" or suit == "♦"
	if mode == "black":
		return suit == "♠" or suit == "♣"
	return mode == "suit" and suit == str(state.get("trump_suit", ""))


func _online_hand_sort_key(card: Dictionary) -> int:
	var special: String = str(card.get("special", ""))
	if special == "mark":
		return 2
	if special == "joker":
		return 0 if str(card.get("joker_color", "")) == "red" else 1
	var idx: int = ["♠", "♥", "♦", "♣"].find(str(card.get("suit", "")))
	if idx < 0:
		idx = 4
	var group: int = 2 if _online_is_trump(card) else 1
	return group * 1000 + idx * 100 + int(card.get("rank", 0))


func _online_hand_before(a: Dictionary, b: Dictionary) -> bool:
	return _online_hand_sort_key(a) < _online_hand_sort_key(b)


func _sorted_online_hand() -> Array:
	var cards: Array = (state.get("your_hand", []) as Array).duplicate()
	cards.sort_custom(_online_hand_before)
	return cards


func _online_has_move() -> bool:
	var cards: Array = state.get("your_hand", [])
	var table: Array = state.get("table", [])
	if table.is_empty():
		for card in cards:
			if str(card.get("special", "")) == "":
				return true
		return false
	var attacker: bool = your_seat == int(state.get("attacker", -1))
	var ranks: Array[int] = []
	var targets: Array = []
	var defended_count: int = 0
	for pair in table:
		for card in [pair["attack"], pair.get("defense")]:
			if card != null:
				targets.append(card)
				var rank: int = 100 if str(card.get("special", "")) == "mark" else int(card.get("copy_rank", -1)) if str(card.get("special", "")) == "joker" else int(card.get("rank", 0))
				if not ranks.has(rank):
					ranks.append(rank)
		if pair.get("defense") != null:
			defended_count += 1
	if attacker:
		var limit: int = mini(8 if int(state.get("round", 1)) == 1 else 10, maxi(table.size(), int(state.get("opponent_count", 0)) + defended_count))
		if table.size() >= limit or table.size() >= 10:
			return false
		for card in cards:
			if str(card.get("special", "")) == "mark":
				continue
			if str(card.get("special", "")) == "joker":
				if not targets.is_empty():
					return true
			elif ranks.has(int(card.get("rank", -1))):
				return true
		return false
	# Defending: consider jokers as copy of any visible card, incl. Mark.
	var transfer_open: bool = defended_count == 0 and table.size() < (8 if int(state.get("round", 1)) == 1 else 10)
	for card in cards:
		var special: String = str(card.get("special", ""))
		if transfer_open:
			if special == "joker" and not targets.is_empty():
				return true
			if special == "" and ranks.has(int(card.get("rank", 0))):
				return true
		for pair in table:
			if pair.get("defense") != null:
				continue
			var attack_card: Dictionary = pair["attack"]
			if special == "mark" or special == "joker":
				return true
			var defense_rank: int = int(card.get("rank", 0))
			var attack_rank: int = int(attack_card.get("rank", 0))
			var defense_suit: String = str(card.get("suit", ""))
			var attack_suit: String = str(attack_card.get("suit", ""))
			var attack_special: String = str(attack_card.get("special", ""))
			if attack_special == "mark":
				continue
			var d_trump: bool = _online_is_trump(card)
			var a_trump: bool = _online_is_trump(attack_card)
			if a_trump and d_trump and (defense_rank > attack_rank or (defense_rank == attack_rank and defense_suit != attack_suit and str(state.get("trump_mode", "")) in ["red", "black"])):
				return true
			if not a_trump and (d_trump or (defense_suit == attack_suit and defense_rank > attack_rank)):
				return true
	return false


func _online_action_highlight(button: Button, active: bool) -> void:
	button.add_theme_stylebox_override("normal", _neon_style(Color("#6E329F"), Color("#FFE293"), 2, 6) if active else _neon_style(Color("#241030"), Color("#9961CB"), 2, 4))
	button.add_theme_font_size_override("font_size", 17 if active else 14)
	button.add_theme_color_override("font_color", Color.WHITE)


func _update_online_recommended_action() -> void:
	var table: Array = state.get("table", [])
	var attacker: bool = your_seat == int(state.get("attacker", -1))
	var taking: bool = bool(state.get("taking", false))
	var every_defended: bool = not table.is_empty()
	for pair in table:
		if pair.get("defense") == null:
			every_defended = false
	var want: String = ""
	var votes: Array = state.get("finish_ready", [false, false])
	var already_ready: bool = your_seat >= 0 and your_seat < votes.size() and bool(votes[your_seat])
	if not table.is_empty() and str(state.get("stage", "")) != "finished":
		if taking and attacker and not _online_has_move():
			want = "finish"
		elif not taking and every_defended and not already_ready and not _online_has_move():
			want = "finish"
		elif not attacker and not taking and not every_defended and not _online_has_move():
			want = "take"
	if highlighted_online_action != want:
		highlighted_online_action = want
		_online_action_highlight(action_finish, want == "finish")
		_online_action_highlight(action_take, want == "take")


func _on_hand_selected(cid: int) -> void:
	selected_card_id = -1 if selected_card_id == cid else cid
	_render_hand()
	_sound("card")
	if selected_card_id >= 0:
		_info("Карта выбрана. Нажми на место на столе для действия.")


func _on_table_selected(pair_index: int) -> void:
	if selected_card_id < 0:
		_info("Сначала выбери карту из своей руки.")
		return
	var pairs: Array = state.get("table", [])
	var action: String = ""
	if your_seat == int(state.get("attacker", -1)):
		if pair_index < pairs.size():
			_info("Для подкидывания выбери свободную ячейку.")
			return
		action = "attack" if pairs.is_empty() else "throw"
	else:
		if pair_index < pairs.size():
			var pair: Dictionary = pairs[pair_index]
			action = "defend" if pair.get("defense") == null else "replace"
		else:
			action = "transfer"
	var chosen: Dictionary = {}
	for c in state.get("your_hand", []):
		if int(c.get("id", -1)) == selected_card_id:
			chosen = c
			break
	if chosen.is_empty():
		return
	# Transfer works both ways, including after a Joker copied a rank.
	# The original attacker can counter-transfer the whole pile by choosing
	# another card of that rank; no extra Transfer button is required.
	if action == "defend":
		var max_attacks: int = 8 if int(state.get("round", 1)) == 1 else 10
		var valid_transfer: bool = pairs.size() < max_attacks
		var attack_ranks: Array[int] = []
		for pair in pairs:
			if pair.get("defense") != null:
				valid_transfer = false
			var attack_card: Dictionary = pair.get("attack", {})
			var rank: int = int(attack_card.get("copy_rank", -1)) if str(attack_card.get("special", "")) == "joker" else (100 if str(attack_card.get("special", "")) == "mark" else int(attack_card.get("rank", -1)))
			if not attack_ranks.has(rank):
				attack_ranks.append(rank)
		if valid_transfer and (str(chosen.get("special", "")) == "joker" or (str(chosen.get("special", "")) != "mark" and attack_ranks.has(int(chosen.get("rank", -1))))):
			action = "transfer"
			pair_index = -1
	if str(chosen.get("special", "")) == "joker":
		_show_joker_choices(action, pair_index)
		return
	_send_action(action, pair_index)


func _show_joker_choices(verb: String, pair_index: int) -> void:
	pending_joker_verb = verb
	pending_pair_index = pair_index
	for node in joker_choices.get_children():
		node.queue_free()
	var targets: Array = []
	var seen: Dictionary = {}
	for pair in state.get("table", []):
		for c in [pair.get("attack"), pair.get("defense")]:
			if c == null:
				continue
			var identity: String = _short_name(c)
			if seen.has(identity):
				continue
			seen[identity] = true
			targets.append(c)
	if targets.is_empty():
		_info("Джокер не может начать атаку и копирует только открытые карты.")
		return
	for c in targets:
		var caption: String = _short_name(c)
		var btn: Button = _button("КОПИРОВАТЬ: " + caption)
		btn.pressed.connect(_copy_target.bind(int(c.get("id", -1))))
		joker_choices.add_child(btn)
	joker_dialog.popup_centered(Vector2i(360, mini(540, 120 + 48 * targets.size())))


func _copy_target(cid: int) -> void:
	joker_dialog.hide()
	_send_action(pending_joker_verb, pending_pair_index, cid)


func _short_name(card: Dictionary) -> String:
	if str(card.get("special", "")) == "mark":
		return "МЕТКА"
	var rank: int = int(card.get("rank", 0))
	var suit: String = str(card.get("suit", ""))
	if str(card.get("special", "")) == "joker":
		rank = int(card.get("copy_rank", -1))
		suit = str(card.get("copy_suit", ""))
		if rank == 100:
			return "ДЖОКЕР → МЕТКА"
		if rank < 2:
			return "ДЖОКЕР"
	return (str(rank) if rank < 11 else ["В", "Д", "К", "Т"][rank - 11]) + suit


func _face(card: Dictionary) -> Texture2D:
	var key: String = ""
	if str(card.get("special", "")) == "mark":
		key = "mark"
	elif str(card.get("special", "")) == "joker":
		key = "joker_" + str(card.get("joker_color", "red"))
	else:
		var suit: String = str(card.get("suit", ""))
		var code: String = ""
		match suit:
			"♠": code = "s"
			"♥": code = "h"
			"♦": code = "d"
			"♣": code = "c"
		key = code + "_" + str(int(card.get("rank", 2)))
	if key.is_empty():
		return null
	return load(FACE_PATH + key + ".png") as Texture2D


func _render_game() -> void:
	var seat: int = int(state.get("your_seat", -1))
	var attack: bool = seat == int(state.get("attacker", -1))
	var table: Array = state.get("table", [])
	header.text = "СОПЕРНИК: %s  ·  %d карт" % [
		str(state.get("opponent_name", "Игрок")), int(state.get("opponent_count", 0))
	]
	room_label.text = "БЫСТРАЯ ИГРА" if quick_match_room else "КОМНАТА: " + current_code
	my_turn_label.text = "РАУНД %d" % int(state.get("round", 1))
	var mode: String = str(state.get("trump_mode", ""))
	var trump: String = str(state.get("trump_suit", ""))
	if mode == "none": trump = "БЕЗ КОЗЫРЯ"
	elif mode == "red": trump = "♥ + ♦"
	elif mode == "black": trump = "♠ + ♣"
	deck_label.text = "КОЛОДА · %d\nБИТО · %d" % [
		int(state.get("deck_count", 0)), int(state.get("discard_count", 0))
	]
	if online_trump_caption != null:
		online_trump_caption.text = "КОЗЫРЬ\n%s" % trump
	if online_player_caption != null:
		online_player_caption.text = "%s · %d карт  •  %s" % [
			str(state.get("your_name", "Игрок")),
			(state.get("your_hand", []) as Array).size(),
			"ТВОЙ ХОД" if attack else "ЗАЩИТА"
		]
	_clear_online_children(enemy_row)
	var enemy_cards: int = int(state.get("opponent_count", 0))
	enemy_caption.text = ""  # The number is now in the opponent's heading.
	var back_texture: Texture2D = load("res://assets/shop/back_default.png") as Texture2D
	for i in range(mini(enemy_cards, 24)):
		var back: TextureRect = TextureRect.new()
		back.name = "OpponentBack_%d" % i
		back.texture = back_texture
		back.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		back.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		back.mouse_filter = Control.MOUSE_FILTER_IGNORE
		back.custom_minimum_size = Vector2(46.0, 65.0)
		back.size = back.custom_minimum_size
		enemy_row.add_child(back)
	_queue_online_enemy_fan_layout()
	for old in table_grid.get_children(): old.queue_free()
	var screen_width: float = get_viewport_rect().size.x
	# Match the bot's compact 2×5 board, including its framed margins.
	# Fit all ten slots without horizontal scroll, even at 320px.
	var board_width: float = maxf(260.0, screen_width - 55.0)
	var cw: float = clampf((board_width - 36.0) / 5.0, 40.0, 78.0)
	var compact_height: bool = get_viewport_rect().size.y < 720.0
	var ch: float = cw * (1.26 if compact_height else 1.42)
	for i in range(10):
		var cell: Button = _button("")
		cell.name = "OnlineTableSlot_%d" % i
		cell.custom_minimum_size = Vector2(cw, ch + 3.0)
		cell.clip_contents = true
		cell.add_theme_stylebox_override("normal", _neon_style(Color("#1C0B2B"), Color("#6E4B93"), 1, 0))
		cell.add_theme_stylebox_override("hover", _neon_style(Color("#321446"), Color("#D5B1FF"), 2, 1))
		if DisplayServer.get_name() != "headless" and i < table.size():
			cell.pivot_offset = Vector2(cw, ch) * 0.5
			cell.modulate.a = 0.0
			var swoop: Tween = cell.create_tween()
			swoop.tween_property(cell, "modulate:a", 1.0, 0.24).set_delay(float(i) * 0.025)

		cell.pressed.connect(_on_table_selected.bind(i))
		if i < table.size():
			cell.add_theme_stylebox_override("normal", _neon_style(Color("#080411"), Color("#AC6BEA"), 2, 2))
			var item: Dictionary = table[i]
			_add_card_art(cell, item["attack"], cw, ch, false)
			if item.get("defense") != null:
				_add_card_art(cell, item["defense"], cw, ch, true)
		table_grid.add_child(cell)
	_render_hand()
	var finished: bool = str(state.get("stage", "")) == "finished"
	var taking: bool = bool(state.get("taking", false))
	var all_defended: bool = not table.is_empty()
	for pair in table:
		if pair.get("defense") == null:
			all_defended = false
	var votes: Array = state.get("finish_ready", [false, false])
	var already_ready: bool = seat >= 0 and seat < votes.size() and bool(votes[seat])
	action_finish.disabled = finished or table.is_empty() or (taking and not attack) or (not taking and (not all_defended or already_ready))
	action_take.disabled = finished or attack or table.is_empty() or taking or take_request_pending
	action_draw.disabled = finished or taking or int(state.get("deck_count", 0)) == 0 or (state.get("your_hand", []) as Array).size() >= 6
	if taking:
		action_finish.text = "ГОТОВО" if attack else "ЖДЁМ"
	elif already_ready:
		action_finish.text = "БИТО ✓"
	else:
		action_finish.text = "БИТО!"
	_update_online_recommended_action()
	_sync_online_action_dock()
	if finished:
		var winner: Variant = state.get("winner", null)
		_info("НИЧЬЯ!" if winner == null else ("ТЫ ПОБЕДИЛ!" if int(winner) == seat else "ПОБЕДИЛ СОПЕРНИК"))
	else:
		_info(str(state.get("notice", "Выбери карту на столе.")))


func _add_card_art(parent: Control, card: Dictionary, w: float, h: float, defense: bool) -> void:
	var picture: TextureRect = TextureRect.new()
	picture.texture = _face(card)
	picture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	picture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	picture.mouse_filter = Control.MOUSE_FILTER_IGNORE
	picture.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	picture.position = Vector2(w * 0.36, h * 0.32) if defense else Vector2.ZERO
	picture.custom_minimum_size = Vector2(w * 0.62, h * 0.62) if defense else Vector2(w, h)
	picture.size = picture.custom_minimum_size
	parent.add_child(picture)
	if card.get("special") == "joker" and int(card.get("copy_rank", -1)) >= 2:
		var badge: Label = _label(_short_name(card), 10)
		badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
		badge.add_theme_color_override("font_color", Color.YELLOW)
		picture.add_child(badge)


func _clear_online_children(container: Node) -> void:
	# Remove immediately so a queued deletion never appears in fan layout.
	for child in container.get_children():
		container.remove_child(child)
		child.queue_free()


func _render_hand() -> void:
	_clear_online_children(hand_row)
	var hand: Array = _sorted_online_hand()
	for i in range(hand.size()):
		var card: Dictionary = hand[i]
		var cid: int = int(card.get("id", -1))
		var btn: Button = _button("")
		btn.name = "OnlineHandCard_%d" % cid
		btn.tooltip_text = _short_name(card)
		btn.clip_contents = true
		btn.custom_minimum_size = Vector2(68.0, 96.0)
		btn.size = btn.custom_minimum_size
		btn.add_theme_stylebox_override("normal", _style(Color("#05030A"), PURPLE))
		btn.add_theme_stylebox_override("hover", _style(Color("#211132"), Color("#F2D8FF")))
		btn.add_theme_stylebox_override("pressed", _style(Color("#170D26"), Color("#FFE9AA")))
		_add_card_art(btn, card, 68.0, 96.0, false)
		btn.pressed.connect(_on_hand_selected.bind(cid))
		hand_row.add_child(btn)
	_queue_online_hand_fan_layout()


func _queue_online_hand_fan_layout() -> void:
	if online_hand_layout_queued or not is_inside_tree():
		return
	online_hand_layout_queued = true
	call_deferred("_run_queued_online_hand_layout")


func _run_queued_online_hand_layout() -> void:
	online_hand_layout_queued = false
	_layout_online_hand_fan()


func _queue_online_enemy_fan_layout() -> void:
	if online_enemy_layout_queued or not is_inside_tree():
		return
	online_enemy_layout_queued = true
	call_deferred("_run_queued_online_enemy_layout")


func _run_queued_online_enemy_layout() -> void:
	online_enemy_layout_queued = false
	_layout_online_enemy_fan()


func _layout_online_hand_fan() -> void:
	if hand_row == null or hand_scroll == null or not is_instance_valid(hand_row):
		return
	var count: int = hand_row.get_child_count()
	var width_available: float = maxf(260.0, hand_scroll.size.x)
	var edge: float = clampf(width_available * 0.018, 4.0, 10.0)
	var available: float = width_available - edge * 2.0
	var card_w: float = clampf(width_available / 5.9, 48.0, 84.0)
	if get_viewport_rect().size.y < 720.0:
		card_w *= 0.90
	if count > 1 and count <= 6:
		card_w = minf(card_w, maxf(42.0, (available - float(count - 1) * 3.0) / float(count)))
	elif count > 6:
		card_w = maxf(49.0, card_w * 0.87)
	var card_h: float = card_w * (1.29 if get_viewport_rect().size.y < 720.0 else 1.42)
	var step_x: float = card_w
	if count > 1:
		step_x = minf(card_w + 3.0, maxf(8.0, (available - card_w) / float(count - 1)))
	var fan_width: float = card_w + step_x * float(maxi(0, count - 1))
	var left: float = maxf(edge, (width_available - fan_width) * 0.5)
	var height_needed: float = card_h + (18.0 if get_viewport_rect().size.y < 720.0 else 26.0)
	hand_row.custom_minimum_size = Vector2(width_available, height_needed)
	if absf(hand_scroll.custom_minimum_size.y - height_needed) > 0.5:
		hand_scroll.custom_minimum_size.y = height_needed
	for i in range(count):
		var button: Button = hand_row.get_child(i) as Button
		if button == null:
			continue
		var cid: int = int(button.name.trim_prefix("OnlineHandCard_"))
		var picked: bool = cid == selected_card_id
		var spread: float = (2.0 * float(i) / float(count - 1) - 1.0) if count > 1 else 0.0
		button.custom_minimum_size = Vector2(card_w, card_h)
		button.size = button.custom_minimum_size
		# Update the face image when orientation or width changes.
		for inner in button.get_children():
			if inner is TextureRect:
				var pic: TextureRect = inner as TextureRect
				pic.custom_minimum_size = Vector2(card_w, card_h)
				pic.size = pic.custom_minimum_size
		button.position = Vector2(left + float(i) * step_x, 14.0 + absf(spread) * 3.0 - (8.0 if picked else 0.0))
		button.pivot_offset = button.size * 0.5
		button.rotation = spread * (0.042 if count <= 6 else 0.07)
		button.scale = Vector2(1.06, 1.06) if picked else Vector2.ONE
		button.z_index = 70 if picked else i
	hand_scroll.scroll_horizontal = 0


func _layout_online_enemy_fan() -> void:
	if enemy_row == null or not is_instance_valid(enemy_row):
		return
	var count: int = enemy_row.get_child_count()
	var width_available: float = maxf(260.0, enemy_row.size.x)
	var card_w: float = clampf(width_available / 7.3, 40.0, 68.0)
	if get_viewport_rect().size.y < 720.0:
		card_w *= 0.85
	var card_h: float = card_w * (1.27 if get_viewport_rect().size.y < 720.0 else 1.40)
	var step_x: float = minf(card_w * 0.91, maxf(6.0, (width_available - card_w - 20.0) / float(maxi(1, count - 1))))
	var fan_width: float = card_w + step_x * float(maxi(0, count - 1))
	var left: float = maxf(5.0, (width_available - fan_width) * 0.5)
	if absf(enemy_row.custom_minimum_size.y - (card_h + 19.0)) > 0.5:
		enemy_row.custom_minimum_size.y = card_h + 19.0
	for i in range(count):
		var back: TextureRect = enemy_row.get_child(i) as TextureRect
		if back == null:
			continue
		var spread: float = (2.0 * float(i) / float(count - 1) - 1.0) if count > 1 else 0.0
		back.custom_minimum_size = Vector2(card_w, card_h)
		back.size = back.custom_minimum_size
		back.position = Vector2(left + step_x * float(i), 8.0 + absf(spread) * 4.0)
		back.pivot_offset = back.size * 0.5
		back.rotation = spread * 0.08
		back.z_index = i


func _sync_online_action_dock() -> void:
	if online_actions_dock == null or online_scroll == null or game_panel == null:
		return
	var active: bool = page == "online" and game_panel.visible and not state.is_empty()
	online_actions_dock.visible = active
	var small: bool = get_viewport_rect().size.x < 355.0
	online_actions_grid.columns = 2 if small else 3
	var dock_height: float = 124.0 if small else 70.0
	online_actions_dock.offset_top = -dock_height
	online_actions_dock.offset_bottom = -4.0
	online_scroll.offset_bottom = -(dock_height + 2.0) if active else 0.0
	# The verbose notice lives inside the match; no tall status header above it.
	if status_label != null:
		status_label.visible = not active
	if online_game_notice != null:
		online_game_notice.visible = active
	# Fill the viewport even on tall phones. Free height is absorbed by the
	# two spacers, never between hand and dock or inside empty table slots.
	if online_content_margin != null:
		var available_height: float = maxf(0.0, size.y - (dock_height + 2.0 if active else 0.0))
		online_content_margin.custom_minimum_size.y = available_height


func _label(value: String, font_size: int = 15) -> Label:
	var l: Label = Label.new()
	l.text = value
	l.autowrap_mode = TextServer.AUTOWRAP_OFF
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", WHITE)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return l


func _neon_style(fill_color: Color, line_color: Color, border_px: int = 2, glow_px: int = 5) -> StyleBoxFlat:
	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = fill_color
	sb.border_color = line_color
	sb.set_border_width_all(border_px)
	sb.set_corner_radius_all(12)
	sb.set_content_margin_all(7)
	sb.shadow_color = Color(0.57, 0.20, 0.91, 0.33 if glow_px > 0 else 0.0)
	sb.shadow_size = glow_px
	return sb


func _style(color: Color = INK, border: Color = PURPLE) -> StyleBoxFlat:
	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = color
	sb.border_color = border
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(9)
	sb.set_content_margin_all(5)
	return sb


func _button(value: String) -> Button:
	var b: Button = Button.new()
	b.pressed.connect(_sound.bind("tap"))
	b.text = value
	b.add_theme_stylebox_override("normal", _style())
	b.add_theme_stylebox_override("hover", _style(Color("#4B2B6B"), Color("#E9CBFF")))
	b.add_theme_stylebox_override("pressed", _style(Color("#62378A"), WHITE))
	b.add_theme_stylebox_override("disabled", _style(Color("#211829"), Color("#59436B")))
	b.add_theme_color_override("font_color", WHITE)
	b.add_theme_font_size_override("font_size", 14)
	b.custom_minimum_size.y = 43
	return b


func _build() -> void:
	var backdrop: ColorRect = ColorRect.new()
	backdrop.color = Color("#0A0414")
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(backdrop)
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# Subtle purple diamonds behind the playing field, never touchable.
	for i in range(12):
		var mote: Label = Label.new()
		mote.text = "✦"
		mote.add_theme_font_size_override("font_size", 9 if i % 3 else 12)
		mote.add_theme_color_override("font_color", Color(0.65, 0.38, 0.87, 0.19 if i % 2 else 0.28))
		mote.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var px: float = 0.09 + 0.81 * float((i * 7) % 13) / 12.0
		var py: float = 0.08 + 0.84 * float((i * 5) % 13) / 12.0
		mote.anchor_left = px
		mote.anchor_right = px
		mote.anchor_top = py
		mote.anchor_bottom = py
		backdrop.add_child(mote)
	var scrolling: ScrollContainer = ScrollContainer.new()
	online_scroll = scrolling
	scrolling.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scrolling.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	add_child(scrolling)
	scrolling.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var margin: MarginContainer = MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	online_content_margin = margin
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 10)
	scrolling.add_child(margin)
	root = VBoxContainer.new()
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_theme_constant_override("separation", 7)
	margin.add_child(root)
	# One compact navigation bar, not three rows above the cards.
	var top_bar: HBoxContainer = HBoxContainer.new()
	top_bar.name = "OnlineCompactTopBar"
	top_bar.add_theme_constant_override("separation", 5)
	root.add_child(top_bar)
	var back: Button = _button("←")
	back.custom_minimum_size = Vector2(45.0, 42.0)
	back.tooltip_text = "В меню"
	back.add_theme_font_size_override("font_size", 22)
	back.pressed.connect(_do_leave)
	top_bar.add_child(back)
	section_title = _label("✦ JOKERSHIFT · ONLINE ✦", 17)
	section_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	section_title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	top_bar.add_child(section_title)
	room_chat_button = _button("✉")
	room_chat_button.custom_minimum_size = Vector2(45.0, 42.0)
	room_chat_button.tooltip_text = "Чат комнаты"
	room_chat_button.add_theme_font_size_override("font_size", 20)
	room_chat_button.pressed.connect(_open_chat)
	top_bar.add_child(room_chat_button)
	room_chat_button.hide()
	room_label = _label("ОНЛАЙН · КОМНАТА", 12)
	room_label.add_theme_color_override("font_color", PURPLE)
	root.add_child(room_label)
	status_label = _label("Создай комнату или войди по коду друга.", 14)
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(status_label)

	form_panel = PanelContainer.new()
	form_panel.add_theme_stylebox_override("panel", _style())
	root.add_child(form_panel)
	var form: VBoxContainer = VBoxContainer.new()
	form.add_theme_constant_override("separation", 9)
	form_panel.add_child(form)
	var quick: Button = _button("⚡ БЫСТРАЯ ИГРА · СЛУЧАЙНЫЙ ИГРОК")
	quick.name = "QuickMatchButton"
	quick.custom_minimum_size.y = 60
	quick.pressed.connect(_begin_request.bind("quick_match"))
	form.add_child(quick)
	var quick_hint: Label = _label("Найдём игрока на сервере и сразу начнём матч.", 12)
	quick_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	form.add_child(quick_hint)
	var create: Button = _button("✦ СОЗДАТЬ КОМНАТУ")
	create.custom_minimum_size.y = 52
	create.pressed.connect(_begin_request.bind("create"))
	form.add_child(create)
	code_input = LineEdit.new()
	code_input.placeholder_text = "КОД ИЗ 6 ЦИФР"
	code_input.max_length = 6
	code_input.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_NUMBER
	code_input.custom_minimum_size.y = 44
	form.add_child(code_input)
	var join: Button = _button("→ ВОЙТИ ПО КОДУ")
	join.custom_minimum_size.y = 52
	join.pressed.connect(_begin_request.bind("join"))
	form.add_child(join)
	var hint: Label = _label("Создай комнату и отправь другу шесть цифр.", 12)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	form.add_child(hint)
	var connection_toggle: Button = _button("⚙ ПОДКЛЮЧЕНИЕ · НАСТРОИТЬ ОДИН РАЗ")
	connection_toggle.add_theme_font_size_override("font_size", 11)
	connection_toggle.pressed.connect(_toggle_connection)
	form.add_child(connection_toggle)
	connection_panel = VBoxContainer.new()
	connection_panel.add_theme_constant_override("separation", 5)
	form.add_child(connection_panel)
	connection_panel.add_child(_label("АДРЕС ОБЩЕГО СЕРВЕРА", 12))
	url_input = LineEdit.new()
	url_input.placeholder_text = "wss://имя-сервера.onrender.com"
	url_input.custom_minimum_size.y = 44
	url_input.text = _configured_url()
	connection_panel.add_child(url_input)
	var save_connection: Button = _button("СОХРАНИТЬ АДРЕС")
	save_connection.pressed.connect(_save_server_url)
	connection_panel.add_child(save_connection)
	var one_time_help: Label = _label("Адрес Render укажи только один раз — он сохранится в игре.", 11)
	one_time_help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	connection_panel.add_child(one_time_help)
	connection_panel.visible = url_input.text.is_empty()

	waiting_panel = VBoxContainer.new()
	waiting_panel.add_theme_constant_override("separation", 10)
	root.add_child(waiting_panel)
	waiting_title = _label("ОЖИДАНИЕ ВТОРОГО ИГРОКА", 19)
	waiting_panel.add_child(waiting_title)
	copy_room_button = _button("⧉ СКОПИРОВАТЬ КОД")
	copy_room_button.pressed.connect(_copy_room_code)
	waiting_panel.add_child(copy_room_button)
	ready_label = _label("Ожидаем игрока...", 16)
	ready_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	waiting_panel.add_child(ready_label)
	ready_button = _button("Я ГОТОВ")
	ready_button.custom_minimum_size.y = 56
	ready_button.pressed.connect(_do_ready)
	waiting_panel.add_child(ready_button)
	cancel_quick_button = _button("ОТМЕНИТЬ ПОИСК")
	cancel_quick_button.name = "CancelQuickMatchButton"
	cancel_quick_button.pressed.connect(_cancel_quick_search)
	waiting_panel.add_child(cancel_quick_button)
	cancel_quick_button.hide()
	waiting_panel.hide()

	game_panel = VBoxContainer.new()
	game_panel.name = "OnlineMatchLayout"
	game_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	game_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	game_panel.add_theme_constant_override("separation", 5)
	root.add_child(game_panel)

	# Same visual hierarchy as the bot match: opponent, centered 2×5 board,
	# compact deck/trump HUD, then the player's hand above fixed actions.
	header = _label("", 15)
	header.add_theme_color_override("font_color", Color("#E8C5FF"))
	header.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	game_panel.add_child(header)
	enemy_caption = _label("", 11)
	enemy_caption.hide()
	game_panel.add_child(enemy_caption)
	enemy_row = Control.new()
	enemy_row.name = "OnlineOpponentCardFan"
	enemy_row.custom_minimum_size.y = 105.0
	enemy_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	enemy_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	game_panel.add_child(enemy_row)
	enemy_row.resized.connect(_queue_online_enemy_fan_layout)

	online_top_table_spacer = Control.new()
	online_top_table_spacer.name = "OnlineTopBoardSpacer"
	online_top_table_spacer.custom_minimum_size.y = 8.0
	online_top_table_spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	online_top_table_spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	game_panel.add_child(online_top_table_spacer)

	online_table_frame = PanelContainer.new()
	online_table_frame.name = "OnlineTableFrame"
	online_table_frame.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	online_table_frame.add_theme_stylebox_override(
		"panel", _neon_style(Color("#160923"), Color("#B960F9"), 2, 7)
	)
	game_panel.add_child(online_table_frame)
	var board_column: VBoxContainer = VBoxContainer.new()
	board_column.add_theme_constant_override("separation", 5)
	online_table_frame.add_child(board_column)
	my_turn_label = _label("РАУНД 1", 17)
	my_turn_label.add_theme_color_override("font_color", WHITE)
	board_column.add_child(my_turn_label)
	online_table_caption = _label("ИГРОВОЙ СТОЛ · 2 × 5", 12)
	online_table_caption.add_theme_color_override("font_color", Color("#D4A9FD"))
	board_column.add_child(online_table_caption)
	var center: CenterContainer = CenterContainer.new()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	board_column.add_child(center)
	table_grid = GridContainer.new()
	table_grid.name = "OnlineTableSlots"
	table_grid.columns = 5
	table_grid.add_theme_constant_override("h_separation", 4)
	table_grid.add_theme_constant_override("v_separation", 5)
	center.add_child(table_grid)

	var deck_hud: PanelContainer = PanelContainer.new()
	deck_hud.name = "OnlineDeckTrumpHUD"
	deck_hud.custom_minimum_size.y = 60.0
	deck_hud.add_theme_stylebox_override(
		"panel", _neon_style(Color("#241031"), Color("#B45FEF"), 2, 5)
	)
	game_panel.add_child(deck_hud)
	var hud_row: HBoxContainer = HBoxContainer.new()
	hud_row.alignment = BoxContainer.ALIGNMENT_CENTER
	hud_row.add_theme_constant_override("separation", 12)
	deck_hud.add_child(hud_row)
	deck_label = _label("КОЛОДА · 0\nБИТО · 0", 13)
	deck_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hud_row.add_child(deck_label)
	var divider: ColorRect = ColorRect.new()
	divider.color = Color("#8255B5")
	divider.custom_minimum_size = Vector2(2.0, 37.0)
	divider.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud_row.add_child(divider)
	online_trump_caption = _label("КОЗЫРЬ\n♥ ЧЕРВИ", 13)
	online_trump_caption.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	online_trump_caption.add_theme_color_override("font_color", Color("#E6C48A"))
	hud_row.add_child(online_trump_caption)

	online_game_notice = _label("ТВОЙ ХОД", 12)
	online_game_notice.name = "OnlineMatchNotice"
	online_game_notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	online_game_notice.max_lines_visible = 2
	online_game_notice.add_theme_color_override("font_color", Color("#D6BBF0"))
	game_panel.add_child(online_game_notice)
	online_hand_bottom_spacer = Control.new()
	online_hand_bottom_spacer.name = "OnlineHandBottomSpacer"
	online_hand_bottom_spacer.custom_minimum_size.y = 8.0
	online_hand_bottom_spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	online_hand_bottom_spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	game_panel.add_child(online_hand_bottom_spacer)

	online_player_caption = _label("ИГРОК · 6 карт", 15)
	online_player_caption.add_theme_color_override("font_color", Color("#E6C48A"))
	game_panel.add_child(online_player_caption)
	hand_scroll = ScrollContainer.new()
	hand_scroll.name = "OnlinePlayerHandFanScroll"
	hand_scroll.custom_minimum_size.y = 133.0
	hand_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	hand_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	hand_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	game_panel.add_child(hand_scroll)
	hand_row = Control.new()
	hand_row.name = "OnlinePlayerCardFan"
	hand_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hand_row.mouse_filter = Control.MOUSE_FILTER_PASS
	hand_scroll.add_child(hand_row)
	hand_scroll.resized.connect(_queue_online_hand_fan_layout)
	# These buttons are not children of the scrolling match content.
	# Anchored directly to the online screen, they keep their hitboxes in place.
	online_actions_dock = PanelContainer.new()
	online_actions_dock.name = "OnlineFixedActionDock"
	online_actions_dock.mouse_filter = Control.MOUSE_FILTER_STOP
	online_actions_dock.add_theme_stylebox_override("panel", _neon_style(Color("#0D061B"), Color("#9A57D6"), 2, 6))
	add_child(online_actions_dock)
	online_actions_dock.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	online_actions_dock.offset_left = 5.0
	online_actions_dock.offset_right = -5.0
	online_actions_dock.offset_top = -70.0
	online_actions_dock.offset_bottom = -4.0
	online_actions_grid = GridContainer.new()
	online_actions_grid.columns = 3
	online_actions_grid.add_theme_constant_override("h_separation", 5)
	online_actions_grid.add_theme_constant_override("v_separation", 4)
	online_actions_dock.add_child(online_actions_grid)
	# Same button order as versus bot; all three stay outside the scroller.
	action_draw = _button("ДОБРАТЬ")
	action_draw.custom_minimum_size.y = 51.0
	action_draw.add_theme_stylebox_override("normal", _neon_style(Color("#391451"), Color("#C97CFF"), 2, 6))
	action_draw.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	action_draw.pressed.connect(_send_action.bind("draw"))
	online_actions_grid.add_child(action_draw)
	action_finish = _button("БИТО!")
	action_finish.custom_minimum_size.y = 51.0
	action_finish.add_theme_stylebox_override("normal", _neon_style(Color("#241030"), Color("#9961CB"), 2, 4))
	action_finish.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	action_finish.pressed.connect(_send_action.bind("finish"))
	online_actions_grid.add_child(action_finish)
	action_take = _button("ЗАБРАТЬ")
	action_take.custom_minimum_size.y = 51.0
	action_take.add_theme_stylebox_override("normal", _neon_style(Color("#241030"), Color("#9961CB"), 2, 4))
	action_take.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	action_take.pressed.connect(_send_action.bind("take"))
	online_actions_grid.add_child(action_take)
	online_actions_dock.hide()
	resized.connect(_sync_online_action_dock)
	game_panel.hide()

	joker_dialog = AcceptDialog.new()
	joker_dialog.title = "ДЖОКЕР · КОПИРОВАНИЕ"
	add_child(joker_dialog)
	joker_choices = VBoxContainer.new()
	joker_choices.add_theme_constant_override("separation", 4)
	joker_dialog.add_child(joker_choices)

	# Full Friends page opened only from the existing main-menu "Друзья" button.
	friends_section = VBoxContainer.new()
	friends_section.name = "FriendsPage"
	friends_section.size_flags_vertical = Control.SIZE_EXPAND_FILL
	friends_section.add_theme_constant_override("separation", 7)
	root.add_child(friends_section)
	friends_section.add_child(_label("ДРУЗЬЯ · ПРОФИЛЬ И ОБЩЕНИЕ", 17))
	# Same saved address as the room screen; no duplicate IP field.
	friend_server_input = url_input
	var connect_button: Button = _button("↻ ПЕРЕПОДКЛЮЧИТЬСЯ")
	connect_button.pressed.connect(_begin_request.bind("login"))
	friends_section.add_child(connect_button)
	var help: Label = _label("Подключение к серверу происходит автоматически. Для чата друг должен быть в сети.", 11)
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	friends_section.add_child(help)
	var social_scroll: ScrollContainer = ScrollContainer.new()
	social_scroll.name = "FriendsScroll"
	social_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	social_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	social_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	friends_section.add_child(social_scroll)
	social_body = VBoxContainer.new()
	social_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	social_body.add_theme_constant_override("separation", 6)
	social_scroll.add_child(social_body)
	social_id_label = _label("", 12)
	social_id_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	social_body.add_child(social_id_label)
	var copy_button: Button = _button("СКОПИРОВАТЬ МОЙ ID")
	copy_button.pressed.connect(_copy_id)
	social_body.add_child(copy_button)
	social_friend_id = LineEdit.new()
	social_friend_id.placeholder_text = "8 ЦИФР ID ДРУГА"
	social_friend_id.max_length = 8
	social_friend_id.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_NUMBER
	social_body.add_child(social_friend_id)
	var add_button: Button = _button("+ ОТПРАВИТЬ ЗАЯВКУ В ДРУЗЬЯ")
	add_button.pressed.connect(_add_friend)
	social_body.add_child(add_button)
	social_body.add_child(_label("НОВЫЕ ЗАЯВКИ", 13))
	requests_container = VBoxContainer.new()
	social_body.add_child(requests_container)
	social_body.add_child(_label("ОТПРАВЛЕННЫЕ ЗАЯВКИ", 13))
	sent_container = VBoxContainer.new()
	social_body.add_child(sent_container)
	social_body.add_child(_label("СПИСОК ДРУЗЕЙ", 13))
	friends_container = VBoxContainer.new()
	social_body.add_child(friends_container)
	_render_social()
	friends_section.hide()

	# Chat popup, kept separate from the centered card table.
	chat_dialog = AcceptDialog.new()
	chat_dialog.title = "ЧАТ · JOKERSHIFT"
	chat_dialog.exclusive = false
	add_child(chat_dialog)
	var chat_body: VBoxContainer = VBoxContainer.new()
	chat_body.custom_minimum_size = Vector2(260, 340)
	chat_dialog.add_child(chat_body)
	chat_title = _label("ЧАТ", 15)
	chat_body.add_child(chat_title)
	chat_log = TextEdit.new()
	chat_log.editable = false
	chat_log.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	chat_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	chat_log.custom_minimum_size.y = 230
	chat_body.add_child(chat_log)
	chat_input = LineEdit.new()
	chat_input.placeholder_text = "Сообщение (до 240 символов)"
	chat_input.max_length = 240
	chat_input.text_submitted.connect(_submit_chat)
	chat_body.add_child(chat_input)
	var chat_send: Button = _button("ОТПРАВИТЬ")
	chat_send.pressed.connect(_send_chat)
	chat_body.add_child(chat_send)

	invite_dialog = ConfirmationDialog.new()
	invite_dialog.title = "ПРИГЛАШЕНИЕ В ИГРУ"
	invite_dialog.exclusive = false
	invite_dialog.ok_button_text = "ПРИСОЕДИНИТЬСЯ"
	invite_dialog.cancel_button_text = "ОТКЛОНИТЬ"
	invite_dialog.confirmed.connect(_accept_invitation)
	add_child(invite_dialog)
