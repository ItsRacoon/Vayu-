import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';
import 'dart:async';
import 'package:weather_home/city.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: ".env");
  runApp(const WeatherApp());
}

class WeatherApp extends StatelessWidget {
  const WeatherApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Weather Home',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Brightness.dark,
        ),
        cardTheme: CardThemeData(
          elevation: 8,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
        ),
      ),
      home: const WeatherHomePage(),
    );
  }
}

class WeatherHomePage extends StatefulWidget {
  const WeatherHomePage({Key? key}) : super(key: key);

  @override
  _WeatherHomePageState createState() => _WeatherHomePageState();
}

class _WeatherHomePageState extends State<WeatherHomePage>
    with TickerProviderStateMixin {
  final TextEditingController _cityController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  late AnimationController _flipController;
  late Animation<double> _flipAnimation;
  Timer? _debounceTimer;
  SharedPreferences? _prefs;

  // API Keys from .env
  late final String openWeatherApiKey;
  late final String geminiApiKey;

  // State Variables
  String currentCity = "London";
  bool isLoading = false;
  String? error;
  WeatherData? weatherData;
  ClothingRecommendation? clothingRecommendation;
  List<String> citySuggestions = [];
  bool showSuggestions = false;

  // Persistent Storage Keys
  static const String _lastCityKey = 'last_selected_city';
  static const String _lastWeatherDataKey = 'last_weather_data';

  @override
  void initState() {
    super.initState();
    _initializeApp();
  }

  Future<void> _initializeApp() async {
    openWeatherApiKey = dotenv.env['OPENWEATHER_API_KEY'] ?? '';
    geminiApiKey = dotenv.env['GEMINI_API_KEY'] ?? '';

    _flipController = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    );
    _flipAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _flipController, curve: Curves.easeInOut),
    );

    // Initialize shared preferences
    await _initializeSharedPreferences();

    // Load last city or detect location
    await _loadLastCityOrDetectLocation();
  }

  Future<void> _initializeSharedPreferences() async {
    try {
      _prefs = await SharedPreferences.getInstance();

      // Load last saved city
      final lastCity = _prefs?.getString(_lastCityKey);
      if (lastCity != null && lastCity.isNotEmpty) {
        currentCity = lastCity;
        _cityController.text = lastCity;
      }

      // Load last weather data if available
      final lastWeatherDataString = _prefs?.getString(_lastWeatherDataKey);
      if (lastWeatherDataString != null) {
        try {
          final Map<String, dynamic> weatherJson = jsonDecode(
            lastWeatherDataString,
          );
          weatherData = WeatherData.fromJson(weatherJson);
        } catch (e) {
          // If parsing fails, ignore and fetch fresh data
          debugPrint('Error parsing cached weather data: $e');
        }
      }
    } catch (e) {
      debugPrint('Error initializing shared preferences: $e');
    }
  }

  Future<void> _loadLastCityOrDetectLocation() async {
    final lastCity = _prefs?.getString(_lastCityKey);

    if (lastCity != null && lastCity.isNotEmpty) {
      // Use saved city
      currentCity = lastCity;
      _cityController.text = lastCity;
      await _fetchWeatherForCity(lastCity);
    } else {
      // No saved city, detect location
      await _detectLocationAndFetchWeather();
    }
  }

  Future<void> _saveLastCity(String city) async {
    try {
      await _prefs?.setString(_lastCityKey, city);
    } catch (e) {
      debugPrint('Error saving last city: $e');
    }
  }

  Future<void> _saveWeatherData(WeatherData data) async {
    try {
      final weatherJson = data.toJson();
      await _prefs?.setString(_lastWeatherDataKey, jsonEncode(weatherJson));
    } catch (e) {
      debugPrint('Error saving weather data: $e');
    }
  }

  @override
  void dispose() {
    _cityController.dispose();
    _scrollController.dispose();
    _flipController.dispose();
    _debounceTimer?.cancel();
    super.dispose();
  }

  // Location and Weather Fetching
  Future<void> _detectLocationAndFetchWeather() async {
    setState(() {
      isLoading = true;
      error = null;
    });

    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        await _fetchWeatherForCity(currentCity);
        return;
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          await _fetchWeatherForCity(currentCity);
          return;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        await _fetchWeatherForCity(currentCity);
        return;
      }

      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      List<Placemark> placemarks = await placemarkFromCoordinates(
        position.latitude,
        position.longitude,
      );

      if (placemarks.isNotEmpty) {
        String detectedCity = placemarks[0].locality ?? currentCity;
        currentCity = detectedCity;
        _cityController.text = detectedCity;
        await _saveLastCity(detectedCity);
      }

      await _fetchWeatherForCity(currentCity);
    } catch (e) {
      await _fetchWeatherForCity(currentCity);
    }
  }

  Future<void> _fetchWeatherForCity(String city) async {
    if (city.trim().isEmpty) return;

    setState(() {
      isLoading = true;
      error = null;
    });

    try {
      final url = Uri.parse(
        "https://api.openweathermap.org/data/2.5/weather?q=$city&appid=$openWeatherApiKey&units=metric",
      );

      final response = await http.get(url);

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        weatherData = WeatherData.fromJson(data);
        currentCity = city;

        // Save to persistent storage
        await _saveLastCity(city);
        await _saveWeatherData(weatherData!);

        // Fetch clothing recommendations
        await _fetchClothingRecommendations();

        setState(() {
          isLoading = false;
          error = null;
        });
      } else {
        setState(() {
          error = "City not found. Please try another city.";
          isLoading = false;
        });
      }
    } catch (e) {
      setState(() {
        error = "Network error. Please check your connection.";
        isLoading = false;
      });
    }
  }

  Future<void> _fetchClothingRecommendations() async {
    if (weatherData == null) return;

    try {
      final prompt = _buildClothingPrompt();

      final url = Uri.parse(
        "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent",
      );

      final response = await http.post(
        url,
        headers: {
          'Content-Type': 'application/json',
          'X-goog-api-key': geminiApiKey,
        },
        body: json.encode({
          "contents": [
            {
              "parts": [
                {"text": prompt},
              ],
            },
          ],
        }),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['candidates'] != null && data['candidates'].isNotEmpty) {
          final aiResponse =
              data['candidates'][0]['content']['parts'][0]['text'];
          clothingRecommendation = ClothingRecommendation.fromAIResponse(
            aiResponse,
          );
        }
      }
    } catch (e) {
      debugPrint("Clothing recommendation error: $e");
      clothingRecommendation = ClothingRecommendation.fallback(weatherData!);
    }
  }

  String _buildClothingPrompt() {
    return """
    Based on the following weather conditions, provide clothing recommendations in JSON format:
    
    Weather Data:
    - Temperature: ${weatherData!.temperature}°C
    - Feels like: ${weatherData!.feelsLike}°C
    - Condition: ${weatherData!.description}
    - Humidity: ${weatherData!.humidity}%
    - Wind Speed: ${weatherData!.windSpeed} m/s
    
    Please respond with ONLY a JSON object in this exact format:
    {
      "clothing_type": "light/medium/heavy",
      "top_wear": "specific top recommendation",
      "bottom_wear": "specific bottom recommendation",
      "footwear": "specific footwear recommendation",
      "accessories": ["list", "of", "accessories"],
      "carry_umbrella": true/false,
      "carry_jacket": true/false,
      "overall_advice": "brief overall advice"
    }
    """;
  }

  // City Search and Suggestions
  void _onCitySearchChanged(String value) {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 300), () {
      if (value.length > 2) {
        _updateCitySuggestions(value);
      } else {
        setState(() {
          showSuggestions = false;
          citySuggestions.clear();
        });
      }
    });
  }

  void _updateCitySuggestions(String query) {
    final suggestions = popularCities
        .where((city) => city.toLowerCase().contains(query.toLowerCase()))
        .take(5) // Limit to 5 suggestions to avoid overflow
        .toList();

    setState(() {
      citySuggestions = suggestions;
      showSuggestions = suggestions.isNotEmpty;
    });
  }

  void _selectCity(String city) {
    _cityController.text = city;
    setState(() {
      showSuggestions = false;
      citySuggestions.clear();
    });
    _fetchWeatherForCity(city);
  }

  void _flipCard() {
    if (_flipController.isCompleted) {
      _flipController.reverse();
    } else {
      _flipController.forward();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(gradient: _getWeatherGradient()),
        child: SafeArea(
          child: CustomScrollView(
            controller: _scrollController,
            slivers: [
              // City Search Header
              SliverToBoxAdapter(child: _buildResponsiveCitySearchHeader()),

              // Main Content
              SliverToBoxAdapter(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 500),
                  child: isLoading
                      ? _buildLoadingWidget()
                      : error != null
                      ? _buildErrorWidget()
                      : _buildWeatherContent(),
                ),
              ),

              // Add bottom padding for better scrolling
              const SliverToBoxAdapter(child: SizedBox(height: 40)),
            ],
          ),
        ),
      ),
    );
  }

  LinearGradient _getWeatherGradient() {
    if (weatherData == null) {
      return LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Colors.blue.shade400, Colors.blue.shade600],
      );
    }

    final hour = DateTime.now().hour;
    final condition = weatherData!.description.toLowerCase();

    // Time-based colors
    List<Color> baseColors;
    if (hour >= 6 && hour < 12) {
      baseColors = [Colors.orange.shade300, Colors.blue.shade400];
    } else if (hour >= 12 && hour < 18) {
      baseColors = [Colors.blue.shade400, Colors.blue.shade600];
    } else if (hour >= 18 && hour < 20) {
      baseColors = [Colors.orange.shade400, Colors.purple.shade400];
    } else {
      baseColors = [Colors.purple.shade900, Colors.blue.shade900];
    }

    // Weather condition adjustments
    if (condition.contains('rain')) {
      baseColors = [Colors.grey.shade600, Colors.grey.shade800];
    } else if (condition.contains('snow')) {
      baseColors = [Colors.blue.shade200, Colors.blue.shade400];
    } else if (condition.contains('clear')) {
      if (hour >= 6 && hour < 18) {
        baseColors = [Colors.yellow.shade300, Colors.blue.shade400];
      }
    } else if (condition.contains('cloud')) {
      baseColors = [Colors.grey.shade400, Colors.grey.shade600];
    }

    return LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: baseColors,
    );
  }

  Widget _buildResponsiveCitySearchHeader() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Search Input
          Container(
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.25),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white.withValues(alpha: 0.3)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.1),
                  blurRadius: 10,
                  offset: const Offset(0, 5),
                ),
              ],
            ),
            child: TextField(
              controller: _cityController,
              onChanged: _onCitySearchChanged,
              onSubmitted: (value) => _fetchWeatherForCity(value),
              style: const TextStyle(color: Colors.white, fontSize: 16),
              decoration: InputDecoration(
                hintText: "Search for a city...",
                hintStyle: TextStyle(
                  color: Colors.white.withValues(alpha: 0.7),
                ),
                prefixIcon: Icon(
                  Icons.search,
                  color: Colors.white.withValues(alpha: 0.7),
                ),
                suffixIcon: Container(
                  margin: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: IconButton(
                    icon: Icon(
                      Icons.my_location,
                      color: Colors.white.withValues(alpha: 0.9),
                    ),
                    onPressed: _detectLocationAndFetchWeather,
                    tooltip: "Use current location",
                  ),
                ),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 18,
                ),
              ),
            ),
          ),

          // City Suggestions
          if (showSuggestions)
            Container(
              margin: const EdgeInsets.only(top: 8),
              constraints: const BoxConstraints(maxHeight: 200),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.95),
                borderRadius: BorderRadius.circular(15),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.1),
                    blurRadius: 10,
                    offset: const Offset(0, 5),
                  ),
                ],
              ),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: citySuggestions.length,
                itemBuilder: (context, index) {
                  return ListTile(
                    dense: true,
                    title: Text(
                      citySuggestions[index],
                      style: const TextStyle(fontSize: 15),
                    ),
                    trailing: const Icon(Icons.arrow_forward_ios, size: 14),
                    onTap: () => _selectCity(citySuggestions[index]),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildLoadingWidget() {
    return Container(
      height: MediaQuery.of(context).size.height * 0.6,
      child: Center(
        child: Container(
          padding: const EdgeInsets.all(30),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(25),
            border: Border.all(color: Colors.white.withValues(alpha: 0.3)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox(
                    width: 60,
                    height: 60,
                    child: CircularProgressIndicator(
                      valueColor: const AlwaysStoppedAnimation<Color>(
                        Colors.white,
                      ),
                      strokeWidth: 3,
                    ),
                  ),
                  const Icon(Icons.wb_sunny, color: Colors.white, size: 30),
                ],
              ),
              const SizedBox(height: 20),
              const Text(
                "Loading weather data...",
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                "Please wait while we fetch the latest weather information",
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.7),
                  fontSize: 12,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildErrorWidget() {
    return Container(
      height: MediaQuery.of(context).size.height * 0.6,
      child: Center(
        child: Container(
          margin: const EdgeInsets.all(20),
          padding: const EdgeInsets.all(30),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(25),
            border: Border.all(color: Colors.white.withValues(alpha: 0.3)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.1),
                blurRadius: 10,
                offset: const Offset(0, 5),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(15),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(50),
                ),
                child: const Icon(
                  Icons.error_outline,
                  color: Colors.red,
                  size: 48,
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                "Oops! Something went wrong",
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                error!,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.8),
                  fontSize: 14,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 25),
              Wrap(
                spacing: 10,
                children: [
                  ElevatedButton.icon(
                    onPressed: () => _fetchWeatherForCity(currentCity),
                    icon: const Icon(Icons.refresh),
                    label: const Text("Try Again"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white.withValues(alpha: 0.2),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 12,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(15),
                      ),
                    ),
                  ),
                  ElevatedButton.icon(
                    onPressed: _detectLocationAndFetchWeather,
                    icon: const Icon(Icons.my_location),
                    label: const Text("Use Location"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue.withValues(alpha: 0.3),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 12,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(15),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildWeatherContent() {
    return Column(
      children: [
        // Temperature Header
        _buildResponsiveTemperatureHeader(),
        const SizedBox(height: 16),

        // Flip Card
        _buildResponsiveFlipCard(),
        const SizedBox(height: 16),

        // Quick Weather Info
        _buildQuickWeatherInfo(),
      ],
    );
  }

  Widget _buildResponsiveTemperatureHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          // City Name with location icon
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.location_on, color: Colors.white, size: 20),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  currentCity,
                  style: const TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),

          // Current time
          Text(
            _getCurrentTimeString(),
            style: TextStyle(
              fontSize: 14,
              color: Colors.white.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 20),

          // Weather Icon and Temperature
          LayoutBuilder(
            builder: (context, constraints) {
              final isSmallScreen = constraints.maxWidth < 400;

              return TweenAnimationBuilder<double>(
                tween: Tween(begin: 0.0, end: 1.0),
                duration: const Duration(milliseconds: 1000),
                builder: (context, value, child) {
                  return Transform.scale(
                    scale: value,
                    child: isSmallScreen
                        ? _buildVerticalWeatherDisplay()
                        : _buildHorizontalWeatherDisplay(),
                  );
                },
              );
            },
          ),

          const SizedBox(height: 15),

          // Description
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white.withValues(alpha: 0.3)),
            ),
            child: Text(
              weatherData?.description.toUpperCase() ?? "NO DATA",
              style: const TextStyle(
                fontSize: 16,
                color: Colors.white,
                fontWeight: FontWeight.w500,
                letterSpacing: 1.2,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHorizontalWeatherDisplay() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (weatherData?.iconCode != null)
          Container(
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(15),
              border: Border.all(color: Colors.white.withValues(alpha: 0.3)),
            ),
            padding: const EdgeInsets.all(8),
            child: Image.network(
              "http://openweathermap.org/img/wn/${weatherData!.iconCode}@2x.png",
              width: 80,
              height: 80,
              errorBuilder: (context, error, stackTrace) =>
                  const Icon(Icons.wb_sunny, color: Colors.white, size: 80),
            ),
          ),
        const SizedBox(width: 20),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "${weatherData?.temperature.toStringAsFixed(0) ?? '--'}°",
              style: const TextStyle(
                fontSize: 64,
                fontWeight: FontWeight.w300,
                color: Colors.white,
              ),
            ),
            Text(
              "feels like ${weatherData?.feelsLike?.toStringAsFixed(0) ?? '--'}°",
              style: TextStyle(
                fontSize: 14,
                color: Colors.white.withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildVerticalWeatherDisplay() {
    return Column(
      children: [
        if (weatherData?.iconCode != null)
          Container(
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(15),
              border: Border.all(color: Colors.white.withValues(alpha: 0.3)),
            ),
            padding: const EdgeInsets.all(8),
            child: Image.network(
              "http://openweathermap.org/img/wn/${weatherData!.iconCode}@2x.png",
              width: 60,
              height: 60,
              errorBuilder: (context, error, stackTrace) =>
                  const Icon(Icons.wb_sunny, color: Colors.white, size: 60),
            ),
          ),
        const SizedBox(height: 10),
        Text(
          "${weatherData?.temperature.toStringAsFixed(0) ?? '--'}°",
          style: const TextStyle(
            fontSize: 48,
            fontWeight: FontWeight.w300,
            color: Colors.white,
          ),
        ),
        Text(
          "feels like ${weatherData?.feelsLike?.toStringAsFixed(0) ?? '--'}°",
          style: TextStyle(
            fontSize: 12,
            color: Colors.white.withValues(alpha: 0.7),
          ),
        ),
      ],
    );
  }

  String _getCurrentTimeString() {
    final now = DateTime.now();
    final hour = now.hour.toString().padLeft(2, '0');
    final minute = now.minute.toString().padLeft(2, '0');
    return "Updated at $hour:$minute";
  }

  Widget _buildResponsiveFlipCard() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      constraints: const BoxConstraints(maxHeight: 400, minHeight: 300),
      child: GestureDetector(
        onTap: _flipCard,
        child: AnimatedBuilder(
          animation: _flipAnimation,
          builder: (context, child) {
            final isShowingFront = _flipAnimation.value < 0.5;
            return Transform(
              alignment: Alignment.center,
              transform: Matrix4.identity()
                ..setEntry(3, 2, 0.001)
                ..rotateY(_flipAnimation.value * 3.14159),
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(25),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.2),
                      blurRadius: 15,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: isShowingFront
                    ? _buildWeatherDetailsCard()
                    : Transform(
                        alignment: Alignment.center,
                        transform: Matrix4.identity()..rotateY(3.14159),
                        child: _buildClothingCard(),
                      ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildQuickWeatherInfo() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.3)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 300) {
            // Very small screen - single column
            return Column(
              children: [
                _buildQuickInfoItem(Icons.visibility, "Visibility", "10 km"),
                const SizedBox(height: 8),
                _buildQuickInfoItem(Icons.wb_sunny, "UV Index", "5"),
                const SizedBox(height: 8),
                _buildQuickInfoItem(
                  Icons.air,
                  "Wind",
                  "${weatherData?.windSpeed?.toStringAsFixed(1) ?? '--'} m/s",
                ),
              ],
            );
          } else {
            // Normal screen - horizontal layout
            return Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _buildQuickInfoItem(Icons.visibility, "Visibility", "10 km"),
                _buildQuickInfoItem(Icons.wb_sunny, "UV Index", "5"),
                _buildQuickInfoItem(
                  Icons.air,
                  "Wind",
                  "${weatherData?.windSpeed?.toStringAsFixed(1) ?? '--'} m/s",
                ),
              ],
            );
          }
        },
      ),
    );
  }

  Widget _buildQuickInfoItem(IconData icon, String label, String value) {
    return Column(
      children: [
        Icon(icon, color: Colors.white, size: 24),
        const SizedBox(height: 8),
        Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 14,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.7),
            fontSize: 12,
          ),
        ),
      ],
    );
  }

  Widget _buildWeatherDetailsCard() {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withValues(alpha: 0.25),
            Colors.white.withValues(alpha: 0.15),
          ],
        ),
        borderRadius: BorderRadius.circular(25),
        border: Border.all(color: Colors.white.withValues(alpha: 0.3)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Title
            const Text(
              "Weather Details",
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 16),

            // Weather Details Grid
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  // Use SingleChildScrollView to handle overflow
                  return SingleChildScrollView(
                    child: GridView.count(
                      crossAxisCount: 2,
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      crossAxisSpacing: 10,
                      mainAxisSpacing: 10,
                      childAspectRatio: 1.1,
                      children: [
                        _buildWeatherDetailBox(
                          "Feels like",
                          "${weatherData?.feelsLike?.toStringAsFixed(0) ?? '--'}°",
                          Icons.thermostat,
                          Colors.orange,
                        ),
                        _buildWeatherDetailBox(
                          "Humidity",
                          "${weatherData?.humidity ?? '--'}%",
                          Icons.water_drop,
                          Colors.blue,
                        ),
                        _buildWeatherDetailBox(
                          "Wind Speed",
                          "${weatherData?.windSpeed?.toStringAsFixed(1) ?? '--'} m/s",
                          Icons.air,
                          Colors.green,
                        ),
                        _buildWeatherDetailBox(
                          "Pressure",
                          "${weatherData?.pressure?.toStringAsFixed(0) ?? '--'} hPa",
                          Icons.compress,
                          Colors.purple,
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),

            const SizedBox(height: 16),

            // Flip Hint
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.white.withValues(alpha: 0.3)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.checkroom,
                    color: Colors.white.withValues(alpha: 0.8),
                    size: 16,
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    "Tap for clothing advice",
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWeatherDetailBox(
    String label,
    String value,
    IconData icon,
    Color iconColor,
  ) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 5,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: iconColor, size: 20),
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              color: Colors.white.withValues(alpha: 0.7),
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildClothingCard() {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.purple.withValues(alpha: 0.4),
            Colors.pink.withValues(alpha: 0.3),
          ],
        ),
        borderRadius: BorderRadius.circular(25),
        border: Border.all(color: Colors.white.withValues(alpha: 0.3)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            // Header
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.checkroom, color: Colors.white, size: 24),
                  const SizedBox(width: 8),
                  const Text(
                    "What to Wear",
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // Content
            Expanded(
              child: clothingRecommendation != null
                  ? _buildClothingRecommendations()
                  : _buildClothingLoadingState(),
            ),

            const SizedBox(height: 12),

            // Back Hint
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.white.withValues(alpha: 0.3)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.arrow_back,
                    color: Colors.white.withValues(alpha: 0.8),
                    size: 16,
                  ),
                  const SizedBox(width: 6),
                  const Text(
                    "Tap to go back",
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildClothingRecommendations() {
    return SingleChildScrollView(
      child: Column(
        children: [
          _buildClothingItem(
            "Top",
            clothingRecommendation!.topWear,
            Icons.person,
            Colors.blue,
          ),
          const SizedBox(height: 8),
          _buildClothingItem(
            "Bottom",
            clothingRecommendation!.bottomWear,
            Icons.man,
            Colors.green,
          ),
          const SizedBox(height: 8),
          _buildClothingItem(
            "Footwear",
            clothingRecommendation!.footwear,
            Icons.directions_walk,
            Colors.orange,
          ),
          const SizedBox(height: 16),

          // Quick Indicators
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _buildIndicator(
                clothingRecommendation!.carryUmbrella
                    ? Icons.umbrella
                    : Icons.wb_sunny,
                clothingRecommendation!.carryUmbrella ? "Umbrella" : "No Rain",
                clothingRecommendation!.carryUmbrella
                    ? Colors.blue
                    : Colors.orange,
              ),
              _buildIndicator(
                clothingRecommendation!.carryJacket ? Icons.layers : Icons.air,
                clothingRecommendation!.carryJacket ? "Jacket" : "No Jacket",
                clothingRecommendation!.carryJacket
                    ? Colors.brown
                    : Colors.green,
              ),
            ],
          ),

          const SizedBox(height: 12),

          // Overall Advice
          if (clothingRecommendation!.overallAdvice.isNotEmpty)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(15),
                border: Border.all(color: Colors.white.withValues(alpha: 0.3)),
              ),
              child: Column(
                children: [
                  const Icon(Icons.lightbulb, color: Colors.yellow, size: 18),
                  const SizedBox(height: 6),
                  Text(
                    clothingRecommendation!.overallAdvice,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.9),
                      fontSize: 12,
                      height: 1.3,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildClothingLoadingState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(
            valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
          ),
          const SizedBox(height: 12),
          Text(
            "Loading clothing recommendations...",
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.7),
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildClothingItem(
    String category,
    String item,
    IconData icon,
    Color iconColor,
  ) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: iconColor, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  category,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.7),
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  item,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildIndicator(IconData icon, String label, Color color) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.8),
              fontSize: 10,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

// Data Models
class WeatherData {
  final double temperature;
  final double feelsLike;
  final String description;
  final String iconCode;
  final double humidity;
  final double windSpeed;
  final double? pressure;

  WeatherData({
    required this.temperature,
    required this.feelsLike,
    required this.description,
    required this.iconCode,
    required this.humidity,
    required this.windSpeed,
    this.pressure,
  });

  factory WeatherData.fromJson(Map<String, dynamic> json) {
    return WeatherData(
      temperature: (json['main']['temp'] as num).toDouble(),
      feelsLike: (json['main']['feels_like'] as num).toDouble(),
      description: json['weather'][0]['description'] ?? 'Unknown',
      iconCode: json['weather'][0]['icon'] ?? '01d',
      humidity: (json['main']['humidity'] as num).toDouble(),
      windSpeed: (json['wind']['speed'] as num).toDouble(),
      pressure: json['main']['pressure'] != null
          ? (json['main']['pressure'] as num).toDouble()
          : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'main': {
        'temp': temperature,
        'feels_like': feelsLike,
        'humidity': humidity,
        'pressure': pressure,
      },
      'weather': [
        {'description': description, 'icon': iconCode},
      ],
      'wind': {'speed': windSpeed},
    };
  }
}

class ClothingRecommendation {
  final String clothingType;
  final String topWear;
  final String bottomWear;
  final String footwear;
  final List<String> accessories;
  final bool carryUmbrella;
  final bool carryJacket;
  final String overallAdvice;

  ClothingRecommendation({
    required this.clothingType,
    required this.topWear,
    required this.bottomWear,
    required this.footwear,
    required this.accessories,
    required this.carryUmbrella,
    required this.carryJacket,
    required this.overallAdvice,
  });

  factory ClothingRecommendation.fromAIResponse(String aiResponse) {
    try {
      final jsonStart = aiResponse.indexOf('{');
      final jsonEnd = aiResponse.lastIndexOf('}') + 1;

      if (jsonStart != -1 && jsonEnd > jsonStart) {
        final jsonString = aiResponse.substring(jsonStart, jsonEnd);
        final Map<String, dynamic> json = jsonDecode(jsonString);

        return ClothingRecommendation(
          clothingType: json['clothing_type'] ?? 'medium',
          topWear: json['top_wear'] ?? 'Comfortable shirt',
          bottomWear: json['bottom_wear'] ?? 'Long pants',
          footwear: json['footwear'] ?? 'Closed shoes',
          accessories: List<String>.from(json['accessories'] ?? []),
          carryUmbrella: json['carry_umbrella'] ?? false,
          carryJacket: json['carry_jacket'] ?? false,
          overallAdvice:
              json['overall_advice'] ?? 'Dress comfortably for the weather',
        );
      }
    } catch (e) {
      debugPrint('Error parsing AI response: $e');
    }

    return ClothingRecommendation.fallback(null);
  }

  factory ClothingRecommendation.fallback(WeatherData? weatherData) {
    if (weatherData == null) {
      return ClothingRecommendation(
        clothingType: 'medium',
        topWear: 'Comfortable shirt',
        bottomWear: 'Long pants',
        footwear: 'Closed shoes',
        accessories: [],
        carryUmbrella: false,
        carryJacket: false,
        overallAdvice: 'Dress comfortably for the weather',
      );
    }

    final temp = weatherData.temperature;
    final hasRain = weatherData.description.toLowerCase().contains('rain');

    return ClothingRecommendation(
      clothingType: temp < 15
          ? 'heavy'
          : temp > 25
          ? 'light'
          : 'medium',
      topWear: temp < 15
          ? 'Warm sweater'
          : temp > 25
          ? 'Light t-shirt'
          : 'Long-sleeve shirt',
      bottomWear: temp < 15 ? 'Warm pants' : 'Comfortable trousers',
      footwear: hasRain ? 'Waterproof shoes' : 'Comfortable shoes',
      accessories: hasRain ? ['Umbrella'] : [],
      carryUmbrella: hasRain,
      carryJacket: temp < 18,
      overallAdvice:
          'Dress appropriately for ${temp.toStringAsFixed(0)}°C weather',
    );
  }
}
