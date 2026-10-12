--!strict
-- Heatmap color palettes (public/app/plugins/panel/heatmap/palettes.ts
-- quantizeScheme) with the d3-scale-chromatic 3.1 interpolators Grafana
-- calls: ColorBrewer schemes through interpolateRgbBasis, the matplotlib
-- ramps (256 colors) by index, Turbo and Cividis polynomials, Sinebow, and
-- the cubehelix schemes (CubehelixDefault, Warm, Cool, Rainbow) through
-- interpolateCubehelixLong. Opacity mode is one color with an alpha ramp
-- (linear or exponential). Colors are "#rrggbb" (and "#rrggbbaa" for
-- opacity), Grafana's fixed colors, written as literal SVG attributes.

local M = {}

-- colorSchemes: name -> when the palette is reversed ("always", "dark",
-- "light").
-- stylua: ignore
M.INVERT = {
	BrBG = "always", PiYG = "always", PRGn = "always", PuOr = "always", RdBu = "always", RdGy = "always",
	RdYlBu = "always", RdYlGn = "always", Spectral = "always",
	Blues = "dark", Greens = "dark", Greys = "dark", Oranges = "dark", Purples = "dark", Reds = "dark",
	Turbo = "light", Cividis = "light", Viridis = "light", Magma = "light", Inferno = "light", Plasma = "light",
	Warm = "light", Cool = "light", Cubehelix = "light",
	BuGn = "dark", BuPu = "dark", GnBu = "dark", OrRd = "dark", PuBuGn = "dark", PuBu = "dark", PuRd = "dark",
	RdPu = "dark", YlGnBu = "dark", YlGn = "dark", YlOrBr = "dark", YlOrRd = "dark",
	Rainbow = "always", Sinebow = "always",
} :: { [string]: string }

M.DEFAULT_SCHEME = "Spectral"


-- stylua: ignore start
M.BASIS = {
	BrBG = "5430058c510abf812ddfc27df6e8c3f5f5f5c7eae580cdc135978f01665e003c30",
	PiYG = "8e0152c51b7dde77aef1b6dafde0eff7f7f7e6f5d0b8e1867fbc414d9221276419",
	PRGn = "40004b762a839970abc2a5cfe7d4e8f7f7f7d9f0d3a6dba05aae611b783700441b",
	PuOr = "2d004b5427888073acb2abd2d8daebf7f7f7fee0b6fdb863e08214b358067f3b08",
	RdBu = "67001fb2182bd6604df4a582fddbc7f7f7f7d1e5f092c5de4393c32166ac053061",
	RdGy = "67001fb2182bd6604df4a582fddbc7ffffffe0e0e0bababa8787874d4d4d1a1a1a",
	RdYlBu = "a50026d73027f46d43fdae61fee090ffffbfe0f3f8abd9e974add14575b4313695",
	RdYlGn = "a50026d73027f46d43fdae61fee08bffffbfd9ef8ba6d96a66bd631a9850006837",
	Spectral = "9e0142d53e4ff46d43fdae61fee08bffffbfe6f598abdda466c2a53288bd5e4fa2",
	Blues = "f7fbffdeebf7c6dbef9ecae16baed64292c62171b508519c08306b",
	Greens = "f7fcf5e5f5e0c7e9c0a1d99b74c47641ab5d238b45006d2c00441b",
	Greys = "fffffff0f0f0d9d9d9bdbdbd969696737373525252252525000000",
	Oranges = "fff5ebfee6cefdd0a2fdae6bfd8d3cf16913d94801a636037f2704",
	Purples = "fcfbfdefedf5dadaebbcbddc9e9ac8807dba6a51a354278f3f007d",
	Reds = "fff5f0fee0d2fcbba1fc9272fb6a4aef3b2ccb181da50f1567000d",
	BuGn = "f7fcfde5f5f9ccece699d8c966c2a441ae76238b45006d2c00441b",
	BuPu = "f7fcfde0ecf4bfd3e69ebcda8c96c68c6bb188419d810f7c4d004b",
	GnBu = "f7fcf0e0f3dbccebc5a8ddb57bccc44eb3d32b8cbe0868ac084081",
	OrRd = "fff7ecfee8c8fdd49efdbb84fc8d59ef6548d7301fb300007f0000",
	PuBuGn = "fff7fbece2f0d0d1e6a6bddb67a9cf3690c002818a016c59014636",
	PuBu = "fff7fbece7f2d0d1e6a6bddb74a9cf3690c00570b0045a8d023858",
	PuRd = "f7f4f9e7e1efd4b9dac994c7df65b0e7298ace125698004367001f",
	RdPu = "fff7f3fde0ddfcc5c0fa9fb5f768a1dd3497ae017e7a017749006a",
	YlGnBu = "ffffd9edf8b1c7e9b47fcdbb41b6c41d91c0225ea8253494081d58",
	YlGn = "ffffe5f7fcb9d9f0a3addd8e78c67941ab5d238443006837004529",
	YlOrBr = "ffffe5fff7bcfee391fec44ffe9929ec7014cc4c02993404662506",
	YlOrRd = "ffffccffeda0fed976feb24cfd8d3cfc4e2ae31a1cbd0026800026",
}

M.RAMPS = {
	Viridis = "44015444025645045745055946075a46085c460a5d460b5e470d60470e6147106347116447136548146748166848176948186a481a6c481b6d481c6e481d6f481f70482071482173482374482475482576482677482878482979472a7a472c7a472d7b472e7c472f7d46307e46327e46337f463480453581453781453882443983443a83443b84433d84433e85423f854240864241864142874144874045884046883f47883f48893e49893e4a893e4c8a3d4d8a3d4e8a3c4f8a3c508b3b518b3b528b3a538b3a548c39558c39568c38588c38598c375a8c375b8d365c8d365d8d355e8d355f8d34608d34618d33628d33638d32648e32658e31668e31678e31688e30698e306a8e2f6b8e2f6c8e2e6d8e2e6e8e2e6f8e2d708e2d718e2c718e2c728e2c738e2b748e2b758e2a768e2a778e2a788e29798e297a8e297b8e287c8e287d8e277e8e277f8e27808e26818e26828e26828e25838e25848e25858e24868e24878e23888e23898e238a8d228b8d228c8d228d8d218e8d218f8d21908d21918c20928c20928c20938c1f948c1f958b1f968b1f978b1f988b1f998a1f9a8a1e9b8a1e9c891e9d891f9e891f9f881fa0881fa1881fa1871fa28720a38620a48621a58521a68522a78522a88423a98324aa8325ab8225ac8226ad8127ad8128ae8029af7f2ab07f2cb17e2db27d2eb37c2fb47c31b57b32b67a34b67935b77937b87838b9773aba763bbb753dbc743fbc7340bd7242be7144bf7046c06f48c16e4ac16d4cc26c4ec36b50c46a52c56954c56856c66758c7655ac8645cc8635ec96260ca6063cb5f65cb5e67cc5c69cd5b6ccd5a6ece5870cf5773d05675d05477d1537ad1517cd2507fd34e81d34d84d44b86d54989d5488bd6468ed64590d74393d74195d84098d83e9bd93c9dd93ba0da39a2da37a5db36a8db34aadc32addc30b0dd2fb2dd2db5de2bb8de29bade28bddf26c0df25c2df23c5e021c8e020cae11fcde11dd0e11cd2e21bd5e21ad8e219dae319dde318dfe318e2e418e5e419e7e419eae51aece51befe51cf1e51df4e61ef6e620f8e621fbe723fde725",
	Magma = "00000401000501010601010802010902020b02020d03030f03031204041405041606051806051a07061c08071e0907200a08220b09240c09260d0a290e0b2b100b2d110c2f120d31130d34140e36150e38160f3b180f3d19103f1a10421c10441d11471e114920114b21114e22115024125325125527125829115a2a115c2c115f2d11612f116331116533106734106936106b38106c390f6e3b0f703d0f713f0f72400f74420f75440f764510774710784910784a10794c117a4e117b4f127b51127c52137c54137d56147d57157e59157e5a167e5c167f5d177f5f187f601880621980641a80651a80671b80681c816a1c816b1d816d1d816e1e81701f81721f817320817521817621817822817922827b23827c23827e24828025828125818326818426818627818827818928818b29818c29818e2a81902a81912b81932b80942c80962c80982d80992d809b2e7f9c2e7f9e2f7fa02f7fa1307ea3307ea5317ea6317da8327daa337dab337cad347cae347bb0357bb2357bb3367ab5367ab73779b83779ba3878bc3978bd3977bf3a77c03a76c23b75c43c75c53c74c73d73c83e73ca3e72cc3f71cd4071cf4070d0416fd2426fd3436ed5446dd6456cd8456cd9466bdb476adc4869de4968df4a68e04c67e24d66e34e65e44f64e55064e75263e85362e95462ea5661eb5760ec5860ed5a5fee5b5eef5d5ef05f5ef1605df2625df2645cf3655cf4675cf4695cf56b5cf66c5cf66e5cf7705cf7725cf8745cf8765cf9785df9795df97b5dfa7d5efa7f5efa815ffb835ffb8560fb8761fc8961fc8a62fc8c63fc8e64fc9065fd9266fd9467fd9668fd9869fd9a6afd9b6bfe9d6cfe9f6dfea16efea36ffea571fea772fea973feaa74feac76feae77feb078feb27afeb47bfeb67cfeb77efeb97ffebb81febd82febf84fec185fec287fec488fec68afec88cfeca8dfecc8ffecd90fecf92fed194fed395fed597fed799fed89afdda9cfddc9efddea0fde0a1fde2a3fde3a5fde5a7fde7a9fde9aafdebacfcecaefceeb0fcf0b2fcf2b4fcf4b6fcf6b8fcf7b9fcf9bbfcfbbdfcfdbf",
	Inferno = "00000401000501010601010802010a02020c02020e03021004031204031405041706041907051b08051d09061f0a07220b07240c08260d08290e092b10092d110a30120a32140b34150b37160b39180c3c190c3e1b0c411c0c431e0c451f0c48210c4a230c4c240c4f260c51280b53290b552b0b572d0b592f0a5b310a5c320a5e340a5f3609613809623909633b09643d09653e0966400a67420a68440a68450a69470b6a490b6a4a0c6b4c0c6b4d0d6c4f0d6c510e6c520e6d540f6d550f6d57106e59106e5a116e5c126e5d126e5f136e61136e62146e64156e65156e67166e69166e6a176e6c186e6d186e6f196e71196e721a6e741a6e751b6e771c6d781c6d7a1d6d7c1d6d7d1e6d7f1e6c801f6c82206c84206b85216b87216b88226a8a226a8c23698d23698f24699025689225689326679526679727669827669a28659b29649d29649f2a63a02a63a22b62a32c61a52c60a62d60a82e5fa92e5eab2f5ead305dae305cb0315bb1325ab3325ab43359b63458b73557b93556ba3655bc3754bd3853bf3952c03a51c13a50c33b4fc43c4ec63d4dc73e4cc83f4bca404acb4149cc4248ce4347cf4446d04545d24644d34743d44842d54a41d74b3fd84c3ed94d3dda4e3cdb503bdd513ade5238df5337e05536e15635e25734e35933e45a31e55c30e65d2fe75e2ee8602de9612bea632aeb6429eb6628ec6726ed6925ee6a24ef6c23ef6e21f06f20f1711ff1731df2741cf3761bf37819f47918f57b17f57d15f67e14f68013f78212f78410f8850ff8870ef8890cf98b0bf98c0af98e09fa9008fa9207fa9407fb9606fb9706fb9906fb9b06fb9d07fc9f07fca108fca309fca50afca60cfca80dfcaa0ffcac11fcae12fcb014fcb216fcb418fbb61afbb81dfbba1ffbbc21fbbe23fac026fac228fac42afac62df9c72ff9c932f9cb35f8cd37f8cf3af7d13df7d340f6d543f6d746f5d949f5db4cf4dd4ff4df53f4e156f3e35af3e55df2e661f2e865f2ea69f1ec6df1ed71f1ef75f1f179f2f27df2f482f3f586f3f68af4f88ef5f992f6fa96f8fb9af9fc9dfafda1fcffa4",
	Plasma = "0d088710078813078916078a19068c1b068d1d068e20068f2206902406912605912805922a05932c05942e05952f059631059733059735049837049938049a3a049a3c049b3e049c3f049c41049d43039e44039e46039f48039f4903a04b03a14c02a14e02a25002a25102a35302a35502a45601a45801a45901a55b01a55c01a65e01a66001a66100a76300a76400a76600a76700a86900a86a00a86c00a86e00a86f00a87100a87201a87401a87501a87701a87801a87a02a87b02a87d03a87e03a88004a88104a78305a78405a78606a68707a68808a68a09a58b0aa58d0ba58e0ca48f0da4910ea3920fa39410a29511a19613a19814a099159f9a169f9c179e9d189d9e199da01a9ca11b9ba21d9aa31e9aa51f99a62098a72197a82296aa2395ab2494ac2694ad2793ae2892b02991b12a90b22b8fb32c8eb42e8db52f8cb6308bb7318ab83289ba3388bb3488bc3587bd3786be3885bf3984c03a83c13b82c23c81c33d80c43e7fc5407ec6417dc7427cc8437bc9447aca457acb4679cc4778cc4977cd4a76ce4b75cf4c74d04d73d14e72d24f71d35171d45270d5536fd5546ed6556dd7566cd8576bd9586ada5a6ada5b69db5c68dc5d67dd5e66de5f65de6164df6263e06363e16462e26561e26660e3685fe4695ee56a5de56b5de66c5ce76e5be76f5ae87059e97158e97257ea7457eb7556eb7655ec7754ed7953ed7a52ee7b51ef7c51ef7e50f07f4ff0804ef1814df1834cf2844bf3854bf3874af48849f48948f58b47f58c46f68d45f68f44f79044f79143f79342f89441f89540f9973ff9983ef99a3efa9b3dfa9c3cfa9e3bfb9f3afba139fba238fca338fca537fca636fca835fca934fdab33fdac33fdae32fdaf31fdb130fdb22ffdb42ffdb52efeb72dfeb82cfeba2cfebb2bfebd2afebe2afec029fdc229fdc328fdc527fdc627fdc827fdca26fdcb26fccd25fcce25fcd025fcd225fbd324fbd524fbd724fad824fada24f9dc24f9dd25f8df25f8e125f7e225f7e425f6e626f6e826f5e926f5eb27f4ed27f3ee27f3f027f2f227f1f426f1f525f0f724f0f921",
}
-- stylua: ignore end

type RGB = { number }

local function clampi(v: number): number
	-- JS Math.round: halves round up.
	local r = math.floor(v + 0.5)
	if r ~= r then
		return 0
	end
	return math.clamp(r, 0, 255)
end

local function hex(r: number, g: number, b: number): string
	return string.format("#%02x%02x%02x", clampi(r), clampi(g), clampi(b))
end

local function parseHex(s: string, i: number): RGB
	local o = (i - 1) * 6
	return {
		tonumber(string.sub(s, o + 1, o + 2), 16) :: number,
		tonumber(string.sub(s, o + 3, o + 4), 16) :: number,
		tonumber(string.sub(s, o + 5, o + 6), 16) :: number,
	}
end

-- d3-interpolate basis.
local function basis(t1: number, v0: number, v1: number, v2: number, v3: number): number
	local t2 = t1 * t1
	local t3 = t2 * t1
	return (
		(1 - 3 * t1 + 3 * t2 - t3) * v0
		+ (4 - 6 * t2 + 3 * t3) * v1
		+ (1 + 3 * t1 + 3 * t2 - 3 * t3) * v2
		+ t3 * v3
	) / 6
end

-- interpolateRgbBasis over the scheme's largest palette.
local function rgbBasis(colors: string): (number) -> string
	local count = #colors // 6
	local chans: { { number } } = { {}, {}, {} }
	for i = 1, count do
		local c = parseHex(colors, i)
		for k = 1, 3 do
			chans[k][i] = c[k]
		end
	end
	local n = count - 1
	local function spline(values: { number }, t: number): number
		local i: number
		if t <= 0 then
			t = 0
			i = 0
		elseif t >= 1 then
			t = 1
			i = n - 1
		else
			i = math.floor(t * n)
		end
		-- 0-based i as in d3.
		local v1, v2 = values[i + 1], values[i + 2]
		local v0 = if i > 0 then values[i] else 2 * v1 - v2
		local v3 = if i < n - 1 then values[i + 3] else 2 * v2 - v1
		return basis((t - i / n) * n, v0, v1, v2, v3)
	end
	return function(t: number): string
		return hex(spline(chans[1], t), spline(chans[2], t), spline(chans[3], t))
	end
end

-- d3 ramp: 256 colors picked by index.
local function ramp(colors: string): (number) -> string
	local n = #colors // 6
	return function(t: number): string
		local i = math.clamp(math.floor(t * n), 0, n - 1)
		return "#" .. string.sub(colors, i * 6 + 1, i * 6 + 6)
	end
end

local function turbo(t: number): string
	t = math.clamp(t, 0, 1)
	return hex(
		34.61 + t * (1172.33 - t * (10793.56 - t * (33300.12 - t * (38394.49 - t * 14825.05)))),
		23.31 + t * (557.33 + t * (1225.33 - t * (3574.96 - t * (1073.77 + t * 707.56)))),
		27.2 + t * (3211.1 - t * (15327.97 - t * (27814 - t * (22569.18 - t * 6838.66))))
	)
end

local function cividis(t: number): string
	t = math.clamp(t, 0, 1)
	return hex(
		-4.54 - t * (35.34 - t * (2381.73 - t * (6402.7 - t * (7024.72 - t * 2710.57)))),
		32.49 + t * (170.73 + t * (52.82 - t * (131.46 - t * (176.58 - t * 67.37)))),
		81.24 + t * (442.36 - t * (2482.43 - t * (6167.24 - t * (6614.94 - t * 2475.67))))
	)
end

local function sinebow(t: number): string
	t = (0.5 - t) * math.pi
	local a, b, c = math.sin(t), math.sin(t + math.pi / 3), math.sin(t + math.pi * 2 / 3)
	return hex(255 * a * a, 255 * b * b, 255 * c * c)
end

-- d3-color cubehelix -> rgb.
local CA, CB, CC, CD, CE = -0.14861, 1.78277, -0.29227, -0.90649, 1.97294

local function cubehelix(h: number, s: number, l: number): string
	local hr = (h + 120) * math.pi / 180
	local a = s * l * (1 - l)
	local cosh, sinh = math.cos(hr), math.sin(hr)
	return hex(
		255 * (l + a * (CA * cosh + CB * sinh)),
		255 * (l + a * (CC * cosh + CD * sinh)),
		255 * (l + a * (CE * cosh))
	)
end

-- interpolateCubehelixLong between two cubehelix colors.
local function cubehelixLong(h0: number, s0: number, l0: number, h1: number, s1: number, l1: number): (number) -> string
	return function(t: number): string
		return cubehelix(h0 + (h1 - h0) * t, s0 + (s1 - s0) * t, l0 + (l1 - l0) * t)
	end
end

local function rainbow(t: number): string
	if t < 0 or t > 1 then
		t -= math.floor(t)
	end
	local ts = math.abs(t - 0.5)
	return cubehelix(360 * t - 100, 1.5 - 1.5 * ts, 0.8 - 0.9 * ts)
end

local CUSTOM: { [string]: (number) -> string } = {
	Turbo = turbo,
	Cividis = cividis,
	Sinebow = sinebow,
	Rainbow = rainbow,
	Cubehelix = cubehelixLong(300, 0.5, 0, -240, 0.5, 1),
	Warm = cubehelixLong(-100, 0.75, 0.35, 80, 1.5, 0.8),
	Cool = cubehelixLong(260, 0.75, 0.35, 80, 1.5, 0.8),
}

local cache: { [string]: (number) -> string } = {}

-- The d3 interpolator of a scheme name (interpolate<Name>), or nil.
function M.interpolator(name: string): ((number) -> string)?
	local hit = cache[name]
	if hit then
		return hit
	end
	local fn: ((number) -> string)? = CUSTOM[name]
	if fn == nil then
		local b = (M.BASIS :: { [string]: string })[name]
		local r = (M.RAMPS :: { [string]: string })[name]
		if b then
			fn = rgbBasis(b)
		elseif r then
			fn = ramp(r)
		end
	end
	if fn then
		cache[name] = fn
	end
	return fn
end

export type Options = {
	-- "scheme" (default) or "opacity".
	mode: string?,
	scheme: string?,
	-- Opacity mode: the color as "#rrggbb".
	fill: string?,
	-- Opacity mode: "linear" or "exponential" (default).
	scale: string?,
	exponent: number?,
	steps: number?,
	reverse: boolean?,
}

-- quantizeScheme: `steps` colors (2..128, default 128) low to high.
function M.palette(o: Options, dark: boolean): { string }
	local steps = math.clamp(math.floor(o.steps or 128), 2, 128) - 1
	local out: { string } = table.create(steps + 1)
	if o.mode == "opacity" then
		local base = o.fill or "#fa6400"
		local exp = o.exponent or 0.5
		for i = 0, steps do
			local t = i / steps
			local a = if o.scale == "linear" then t else t ^ exp
			out[i + 1] = string.sub(base, 1, 7) .. string.format("%02x", clampi(a * 255))
		end
		return out
	end
	local name = o.scheme or M.DEFAULT_SCHEME
	local fn = M.interpolator(name)
	if fn == nil then
		name = M.DEFAULT_SCHEME
		fn = M.interpolator(name)
	end
	local interp = fn :: (number) -> string
	for i = 0, steps do
		out[i + 1] = interp(i / steps)
	end
	local invert = M.INVERT[name]
	local flip = invert == "always" or (invert == "dark" and dark) or (invert == "light" and not dark)
	if o.reverse then
		flip = not flip
	end
	if flip then
		local n = #out
		for i = 1, n // 2 do
			out[i], out[n + 1 - i] = out[n + 1 - i], out[i]
		end
	end
	return out
end

return M
