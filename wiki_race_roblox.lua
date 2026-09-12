--[[
    WIKI RACE - AUTO SCRIPT (Roblox)
    ==================================
    Basado en análisis de la estructura interna del juego:
    - NavigateArticle RemoteEvent (args: startId, targetId, clickIndex)
    - ArticleLink / ArticleLinkUnderlin con atributo TargetArticleId
    - GUI: LocalLaptopSurfaceGui > WikiPageViewport > ScrollingFrame
             > ArticleContent > LeadSection > LeadText > Paragraph_N
    
    MODO DE USO:
    Pega este script en un Executor (Synapse X, KRNL, etc.)
    mientras estás en una partida activa del juego Wiki Race.
--]]

-- ============================================================
-- SERVICIOS
-- ============================================================
local Players         = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService      = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer
local PlayerGui   = LocalPlayer:WaitForChild("PlayerGui")

-- ============================================================
-- CONFIGURACIÓN
-- ============================================================
local CFG = {
    -- Delay entre cada navegación (segundos). Muy bajo = posible detección
    navigate_delay   = 0.8,
    -- Delay extra antes de iniciar auto-win para que cargue la UI
    start_delay      = 1.5,
    -- Máximo de saltos en búsqueda BFS (seguridad)
    max_bfs_depth    = 15,
    -- Imprimir debug en consola
    debug            = true,
}

-- ============================================================
-- UTILIDADES
-- ============================================================
local function log(msg)
    if CFG.debug then
        print("[WikiRace] " .. tostring(msg))
    end
end

local function wait_for_child_timeout(parent, name, timeout)
    timeout = timeout or 10
    local t = 0
    while t < timeout do
        local child = parent:FindFirstChild(name)
        if child then return child end
        task.wait(0.1)
        t = t + 0.1
    end
    return nil
end

-- ============================================================
-- LOCALIZAR REMOTES
-- ============================================================
-- Busca el RemoteEvent NavigateArticle en ReplicatedStorage
local function find_navigate_remote()
    -- Buscar recursivamente
    local function search(obj)
        for _, child in ipairs(obj:GetChildren()) do
            if child:IsA("RemoteEvent") and child.Name == "NavigateArticle" then
                return child
            end
            if child:IsA("RemoteEvent") and child.Name:lower():find("navigate") then
                return child
            end
            local found = search(child)
            if found then return found end
        end
    end
    return search(ReplicatedStorage)
end

local function find_round_remote()
    local function search(obj)
        for _, child in ipairs(obj:GetChildren()) do
            if child:IsA("RemoteEvent") and (
                child.Name:lower():find("round") or
                child.Name:lower():find("start") or
                child.Name:lower():find("ready")
            ) then
                return child
            end
            local found = search(child)
            if found then return found end
        end
    end
    return search(ReplicatedStorage)
end

-- ============================================================
-- LOCALIZAR GUI DEL JUEGO
-- ============================================================
local function get_wiki_gui()
    -- Buscar LocalLaptopSurfaceGui o WikiLaptopGui
    local gui = PlayerGui:FindFirstChild("LocalLaptopSurfaceGui")
    if not gui then
        gui = PlayerGui:FindFirstChild("WikiLaptopGui")
    end
    if not gui then
        -- Busca cualquier ScreenGui que contenga WikiPage
        for _, sg in ipairs(PlayerGui:GetChildren()) do
            if sg:FindFirstChild("WikiPageViewport", true) then
                gui = sg
                break
            end
        end
    end
    return gui
end

-- ============================================================
-- RECOLECTAR TODOS LOS LINKS DEL ARTÍCULO ACTUAL
-- ============================================================
-- Devuelve tabla: { [TargetArticleId] = GuiObject, ... }
local function get_current_links(gui)
    local links = {}

    local function collect(obj)
        -- Un link tiene TargetArticleId como atributo
        local target = obj:GetAttribute("TargetArticleId")
        if target and target ~= "" then
            links[target] = obj
        end
        for _, child in ipairs(obj:GetChildren()) do
            collect(child)
        end
    end

    if gui then
        collect(gui)
    end

    return links
end

-- ============================================================
-- OBTENER IDs DEL ROUND ACTUAL
-- ============================================================
-- Busca en la GUI los atributos StartArticleId / TargetArticleId del round
local function get_round_info(gui)
    if not gui then return nil, nil end

    -- Buscar en RoundOverlay o en atributos de frames
    local start_id  = nil
    local target_id = nil

    local function search(obj)
        -- Atributos comunes que el juego usa
        local s = obj:GetAttribute("StartArticleId")
            or obj:GetAttribute("StartArticle")
            or obj:GetAttribute("CurrentArticleId")
        local t = obj:GetAttribute("TargetArticleId")
            or obj:GetAttribute("GoalArticleId")
            or obj:GetAttribute("EndArticleId")

        if s and not start_id  then start_id  = s end
        if t and not target_id then target_id = t end

        for _, child in ipairs(obj:GetChildren()) do
            search(child)
            if start_id and target_id then return end
        end
    end

    search(gui)

    -- Si no encontramos via atributos, buscar en Labels
    if not target_id then
        local target_label = gui:FindFirstChild("TargetArticleLabel", true)
        if target_label and target_label:GetAttribute("TargetArticleId") then
            target_id = target_label:GetAttribute("TargetArticleId")
        end
    end

    return start_id, target_id
end

-- ============================================================
-- CONSTRUIR GRAFO DE LINKS (BFS para encontrar ruta)
-- ============================================================
-- Navega en la GUI para encontrar la ruta al target
-- Funciona en memoria con los links ya cargados en la UI

-- Como el juego carga los links del artículo actual en la GUI,
-- hacemos BFS "tocando" links virtuales y esperando que la UI actualice.

local function bfs_find_path(navigate_remote, gui, start_id, target_id)
    log("BFS desde " .. tostring(start_id) .. " → " .. tostring(target_id))

    -- Si ya estamos en el target
    if start_id == target_id then
        return {start_id}
    end

    -- Estructura BFS
    local queue   = {{start_id}}   -- lista de rutas
    local visited = {[start_id] = true}
    local depth   = 0

    while #queue > 0 and depth < CFG.max_bfs_depth do
        local path = table.remove(queue, 1)
        local current = path[#path]
        depth = #path

        log("BFS explorando: " .. current .. " (prof=" .. depth .. ")")

        -- Esperar a que la GUI cargue este artículo
        task.wait(CFG.navigate_delay)

        -- Obtener links disponibles en la UI actual
        local links = get_current_links(gui)
        local link_count = 0
        for _ in pairs(links) do link_count = link_count + 1 end
        log("Links encontrados: " .. link_count)

        -- Comprobar si el target está directamente entre los links
        if links[target_id] then
            log("¡Target encontrado como link directo!")
            local new_path = {}
            for _, v in ipairs(path) do table.insert(new_path, v) end
            table.insert(new_path, target_id)
            return new_path
        end

        -- Agregar links al BFS
        for link_target, _ in pairs(links) do
            if not visited[link_target] then
                visited[link_target] = true
                local new_path = {}
                for _, v in ipairs(path) do table.insert(new_path, v) end
                table.insert(new_path, link_target)
                table.insert(queue, new_path)
            end
        end

        -- Navegar al siguiente nodo del BFS (el más prometedor = primero en cola)
        if #queue > 0 then
            local next_path = queue[1]
            local next_node = next_path[#next_path]
            -- Solo navegar si el nodo es alcanzable desde el artículo actual
            if links[next_node] then
                log("Navegando a: " .. next_node)
                navigate_remote:FireServer({current, next_node, depth})
                task.wait(CFG.navigate_delay)
            end
        end
    end

    return nil  -- no se encontró ruta en el límite dado
end

-- ============================================================
-- AUTO WIN — NAVEGA DIRECTAMENTE AL TARGET
-- ============================================================
-- Método directo: dispara NavigateArticle con el ID del artículo meta.
-- Funciona si el servidor no valida que el link exista en el artículo actual.
-- (Muchos juegos de Roblox no validan esto server-side)

local function auto_win_direct(navigate_remote, gui, target_id)
    log("Auto-Win DIRECTO hacia: " .. tostring(target_id))

    -- Obtener links actuales para tener un click_index válido
    local links = get_current_links(gui)
    local click_index = 1
    for _ in pairs(links) do
        click_index = click_index + 1
        break  -- solo necesitamos un número válido
    end

    -- Disparar el evento como si hubiéramos clickeado el link
    -- Formato visto en SimpleSpy: {startId, targetId, clickNumber}
    local ok, err = pcall(function()
        navigate_remote:FireServer(target_id, target_id, click_index)
    end)

    if not ok then
        -- Intentar otros formatos observados
        pcall(function()
            navigate_remote:FireServer({target_id, target_id, click_index})
        end)
    end

    log("FireServer enviado")
end

-- ============================================================
-- AUTO WIN — NAVEGA TOCANDO LINKS REALES (más seguro)
-- ============================================================
local function auto_win_smart(navigate_remote, gui, current_id, target_id)
    log("Auto-Win SMART: " .. tostring(current_id) .. " → " .. tostring(target_id))

    local links = get_current_links(gui)
    local click_index = 1

    -- Verificar si el target está directamente disponible
    if links[target_id] then
        log("¡Link directo al target encontrado!")
        navigate_remote:FireServer(current_id, target_id, click_index)
        return true
    end

    -- Buscar un link que nos acerque al target
    -- (heurística simple: el primero que encontremos)
    for link_id, _ in pairs(links) do
        log("Navegando via link intermedio: " .. link_id)
        navigate_remote:FireServer(current_id, link_id, click_index)
        task.wait(CFG.navigate_delay)

        -- Refrescar links
        links = get_current_links(gui)
        click_index = click_index + 1

        if links[target_id] then
            log("¡Target alcanzable desde aquí!")
            task.wait(CFG.navigate_delay)
            navigate_remote:FireServer(link_id, target_id, click_index)
            return true
        end
    end

    return false
end

-- ============================================================
-- AUTO START — Iniciar ronda automáticamente
-- ============================================================
local function auto_start(gui)
    log("Auto Start: buscando botón de inicio...")
    -- Buscar botones de inicio en la GUI
    local function find_start_button(obj)
        for _, child in ipairs(obj:GetChildren()) do
            local name_lower = child.Name:lower()
            if child:IsA("TextButton") or child:IsA("ImageButton") then
                if name_lower:find("start") or name_lower:find("play")
                   or name_lower:find("ready") or name_lower:find("begin") then
                    return child
                end
            end
            local found = find_start_button(child)
            if found then return found end
        end
    end

    local btn = find_start_button(PlayerGui)
    if btn then
        log("Botón encontrado: " .. btn.Name .. " — clickeando")
        -- Simular click
        local fire = btn.MouseButton1Click
        if fire then fire:Fire() end
        -- También intentar via función si existe
        local activate = btn.Activated
        if activate then activate:Fire() end
        return true
    end

    log("No se encontró botón de inicio automático")
    return false
end

-- ============================================================
-- AUTO SKIP — Saltar pantallas/transiciones
-- ============================================================
local function auto_skip(gui)
    log("Auto Skip: buscando elementos de transición...")
    local skip_names = {"skip", "continue", "next", "ok", "close", "dismiss", "results"}

    local function find_and_click(obj)
        for _, child in ipairs(obj:GetChildren()) do
            local name_lower = child.Name:lower()
            if (child:IsA("TextButton") or child:IsA("ImageButton"))
                and child.Visible then
                for _, kw in ipairs(skip_names) do
                    if name_lower:find(kw) then
                        log("Skip: clickeando " .. child.Name)
                        local fire = child.MouseButton1Click
                        if fire then pcall(function() fire:Fire() end) end
                        task.wait(0.3)
                        break
                    end
                end
            end
            find_and_click(child)
        end
    end

    find_and_click(PlayerGui)
end

-- ============================================================
-- AUTO CONTINUE — Continuar el juego automáticamente
-- ============================================================
local function auto_continue_loop(navigate_remote, gui)
    log("Auto Continue activado")
    -- Observar cambios en la GUI para continuar automáticamente
    RunService.Heartbeat:Connect(function()
        auto_skip(gui)
    end)
end

-- ============================================================
-- MENÚ PRINCIPAL DEL SCRIPT
-- ============================================================
local function show_menu()
    -- Crear GUI simple en pantalla
    local screen = Instance.new("ScreenGui")
    screen.Name  = "WikiRaceMenu"
    screen.ResetOnSpawn = false
    screen.Parent = PlayerGui

    local frame = Instance.new("Frame")
    frame.Size  = UDim2.new(0, 280, 0, 280)
    frame.Position = UDim2.new(0, 10, 0.5, -140)
    frame.BackgroundColor3 = Color3.fromRGB(20, 20, 30)
    frame.BorderSizePixel = 0
    frame.Parent = screen

    -- Esquinas redondeadas
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 10)
    corner.Parent = frame

    -- Título
    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, 0, 0, 40)
    title.Position = UDim2.new(0, 0, 0, 0)
    title.BackgroundColor3 = Color3.fromRGB(40, 80, 200)
    title.Text = "Wiki Race Script"
    title.TextColor3 = Color3.fromRGB(255, 255, 255)
    title.TextSize = 16
    title.Font = Enum.Font.GothamBold
    title.Parent = frame

    local corner2 = Instance.new("UICorner")
    corner2.CornerRadius = UDim.new(0, 10)
    corner2.Parent = title

    -- Función para crear botones
    local btn_y = 50
    local function make_button(label, color, callback)
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(1, -20, 0, 40)
        btn.Position = UDim2.new(0, 10, 0, btn_y)
        btn.BackgroundColor3 = color
        btn.Text = label
        btn.TextColor3 = Color3.fromRGB(255, 255, 255)
        btn.TextSize = 14
        btn.Font = Enum.Font.Gotham
        btn.BorderSizePixel = 0
        btn.Parent = frame

        local c = Instance.new("UICorner")
        c.CornerRadius = UDim.new(0, 6)
        c.Parent = btn

        btn.MouseButton1Click:Connect(callback)
        btn_y = btn_y + 48
        return btn
    end

    -- Estado
    local status = Instance.new("TextLabel")
    status.Size = UDim2.new(1, -20, 0, 30)
    status.Position = UDim2.new(0, 10, 1, -35)
    status.BackgroundTransparency = 1
    status.Text = "Listo"
    status.TextColor3 = Color3.fromRGB(100, 255, 100)
    status.TextSize = 12
    status.Font = Enum.Font.Gotham
    status.TextXAlignment = Enum.TextXAlignment.Left
    status.Parent = frame

    local function set_status(msg)
        status.Text = "▶ " .. msg
        log(msg)
    end

    -- Localizar remote y GUI del juego
    local navigate_remote = find_navigate_remote()
    local wiki_gui        = get_wiki_gui()

    if not navigate_remote then
        set_status("ERROR: NavigateArticle no encontrado")
    end

    -- ── BOTÓN: AUTO WIN ──────────────────────────────────────
    make_button("⚡ Auto Win", Color3.fromRGB(200, 50, 50), function()
        set_status("Ejecutando Auto Win...")
        task.spawn(function()
            local gui = get_wiki_gui()
            if not gui then
                set_status("GUI no encontrada. ¿Estás en partida?")
                return
            end
            local remote = find_navigate_remote()
            if not remote then
                set_status("Remote no encontrado")
                return
            end

            local _, target_id = get_round_info(gui)
            if not target_id then
                -- Intentar leer de TargetArticleLabel
                local lbl = gui:FindFirstChild("TargetArticleLabel", true)
                if lbl then
                    target_id = lbl:GetAttribute("TargetArticleId")
                end
            end

            if not target_id then
                set_status("No se pudo obtener el artículo meta")
                return
            end

            set_status("Target: " .. target_id)
            task.wait(0.5)
            auto_win_direct(remote, gui, target_id)
            set_status("Auto Win enviado ✓")
        end)
    end)

    -- ── BOTÓN: AUTO START ────────────────────────────────────
    make_button("▶ Auto Start", Color3.fromRGB(50, 150, 50), function()
        set_status("Buscando inicio de ronda...")
        task.spawn(function()
            local gui = get_wiki_gui()
            if auto_start(gui) then
                set_status("Ronda iniciada ✓")
            else
                set_status("No se encontró botón de inicio")
            end
        end)
    end)

    -- ── BOTÓN: AUTO SKIP ─────────────────────────────────────
    make_button("⏭ Auto Skip", Color3.fromRGB(150, 100, 20), function()
        set_status("Skipping...")
        task.spawn(function()
            auto_skip(get_wiki_gui() or PlayerGui)
            set_status("Skip ejecutado ✓")
        end)
    end)

    -- ── BOTÓN: AUTO CONTINUE (toggle) ───────────────────────
    local continue_active = false
    local continue_conn   = nil
    make_button("🔁 Auto Continue: OFF", Color3.fromRGB(80, 80, 180), function()
        continue_active = not continue_active
        local btn_list = frame:GetChildren()
        for _, b in ipairs(btn_list) do
            if b:IsA("TextButton") and b.Text:find("Auto Continue") then
                b.Text = "🔁 Auto Continue: " .. (continue_active and "ON" or "OFF")
                b.BackgroundColor3 = continue_active
                    and Color3.fromRGB(20, 180, 20)
                    or  Color3.fromRGB(80, 80, 180)
            end
        end

        if continue_active then
            set_status("Auto Continue ON")
            local gui = get_wiki_gui() or PlayerGui
            continue_conn = RunService.Heartbeat:Connect(function()
                if not continue_active then
                    continue_conn:Disconnect()
                    return
                end
                pcall(auto_skip, gui)
            end)
        else
            set_status("Auto Continue OFF")
            if continue_conn then
                continue_conn:Disconnect()
                continue_conn = nil
            end
        end
    end)

    -- ── BOTÓN: CERRAR ────────────────────────────────────────
    make_button("✕ Cerrar menú", Color3.fromRGB(60, 60, 60), function()
        screen:Destroy()
    end)

    set_status("GUI cargada — Remote: " .. (navigate_remote and "✓" or "✗"))
end

-- ============================================================
-- INICIALIZACIÓN
-- ============================================================
task.wait(CFG.start_delay)
log("Iniciando Wiki Race Script...")

-- Eliminar menú anterior si existe
local old = PlayerGui:FindFirstChild("WikiRaceMenu")
if old then old:Destroy() end

show_menu()
log("Menú creado. ¡Listo!")
