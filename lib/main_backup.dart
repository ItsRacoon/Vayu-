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
  final PageController _pageController = PageController();
  final TextEditingController _cityController = TextEditingController();
  late AnimationController _flipController;
  late Animation<double> _flipAnimation;
  Timer? _debounceTimer;

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

  @override
  void initState() {
    super.initState();
    openWeatherApiKey = dotenv.env['OPENWEATHER_API_KEY'] ?? '';
    geminiApiKey = dotenv.env['GEMINI_API_KEY'] ?? '';
    _flipController = AnimationController(
      duration: Duration(milliseconds: 800),
      vsync: this,
    );
    _flipAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _flipController, curve: Curves.easeInOut),
    );

    _detectLocationAndFetchWeather();
  }

  @override
  void dispose() {
    _pageController.dispose();
    _cityController.dispose();
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
      // Log error (in production, use proper logging)
      debugPrint("Clothing recommendation error: $e");
      // Fallback recommendations
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
    _debounceTimer = Timer(Duration(milliseconds: 300), () {
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
          child: Column(
            children: [
              // Enhanced City Search Header
              _buildEnhancedCitySearchHeader(),

              // Main Content
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 500),
                  child: isLoading
                      ? _buildEnhancedLoadingWidget()
                      : error != null
                      ? _buildEnhancedErrorWidget()
                      : _buildEnhancedWeatherContent(),
                ),
              ),
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
    final temp = weatherData!.temperature;
    final condition = weatherData!.description.toLowerCase();

    // Time-based colors
    List<Color> baseColors;
    if (hour >= 6 && hour < 12) {
      // Morning
      baseColors = [Colors.orange.shade300, Colors.blue.shade400];
    } else if (hour >= 12 && hour < 18) {
      // Afternoon
      baseColors = [Colors.blue.shade400, Colors.blue.shade600];
    } else if (hour >= 18 && hour < 20) {
      // Evening
      baseColors = [Colors.orange.shade400, Colors.purple.shade400];
    } else {
      // Night
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

  Widget _buildEnhancedCitySearchHeader() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
      child: Column(
        children: [
          // Enhanced Search Input
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

          // Enhanced City Suggestions
          if (showSuggestions)
            Container(
              margin: const EdgeInsets.only(top: 10),
              constraints: const BoxConstraints(maxHeight: 150),
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

  Widget _buildEnhancedLoadingWidget() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(30),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(25),
              border: Border.all(color: Colors.white.withValues(alpha: 0.3)),
            ),
            child: Column(
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
        ],
      ),
    );
  }

  Widget _buildEnhancedErrorWidget() {
    return Center(
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
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
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
                const SizedBox(width: 10),
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
    );
  }

  Widget _buildEnhancedWeatherContent() {
    return SingleChildScrollView(
      child: Column(
        children: [
          // Enhanced Temperature Header
          _buildEnhancedTemperatureHeader(),
          const SizedBox(height: 20),

          // Enhanced Flipcard for details
          _buildEnhancedFlipCard(),
          const SizedBox(height: 20),

          // Quick Weather Info Bar
          _buildQuickWeatherInfoBar(),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  Widget _buildEnhancedTemperatureHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        children: [
          // City Name with location icon
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.location_on, color: Colors.white, size: 20),
              const SizedBox(width: 8),
              Text(
                currentCity,
                style: const TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
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

          // Weather Icon and Temperature with animation
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0.0, end: 1.0),
            duration: const Duration(milliseconds: 1000),
            builder: (context, value, child) {
              return Transform.scale(
                scale: value,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (weatherData?.iconCode != null)
                      Container(
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(15),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.3),
                          ),
                        ),
                        padding: const EdgeInsets.all(8),
                        child: Image.network(
                          "http://openweathermap.org/img/wn/${weatherData!.iconCode}@2x.png",
                          width: 80,
                          height: 80,
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
                ),
              );
            },
          ),

          const SizedBox(height: 15),

          // Description with styling
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
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
            ),
          ),
        ],
      ),
    );
  }

  String _getCurrentTimeString() {
    final now = DateTime.now();
    final hour = now.hour.toString().padLeft(2, '0');
    final minute = now.minute.toString().padLeft(2, '0');
    return "Updated at $hour:$minute";
  }

  Widget _buildEnhancedFlipCard() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20),
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
                height: 380,
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
                    ? _buildEnhancedWeatherDetailsCard()
                    : Transform(
                        alignment: Alignment.center,
                        transform: Matrix4.identity()..rotateY(3.14159),
                        child: _buildEnhancedClothingCard(),
                      ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildQuickWeatherInfoBar() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20),
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _buildQuickInfoItem(
            Icons.visibility,
            "Visibility",
            "10 km", // You can add this to your weather data
          ),
          _buildQuickInfoItem(
            Icons.wb_sunny,
            "UV Index",
            "5", // You can add this to your weather data
          ),
          _buildQuickInfoItem(
            Icons.air,
            "Wind",
            "${weatherData?.windSpeed?.toStringAsFixed(1) ?? '--'} m/s",
          ),
        ],
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

  Widget _buildEnhancedWeatherDetailsCard() {
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
        padding: const EdgeInsets.all(25),
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
            const SizedBox(height: 20),

            // Enhanced Weather Details Grid
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisSpacing: 15,
              mainAxisSpacing: 15,
              children: [
                _buildEnhancedWeatherDetailBox(
                  "Feels like",
                  "${weatherData?.feelsLike?.toStringAsFixed(0) ?? '--'}°",
                  Icons.thermostat,
                  Colors.orange,
                ),
                _buildEnhancedWeatherDetailBox(
                  "Humidity",
                  "${weatherData?.humidity ?? '--'}%",
                  Icons.water_drop,
                  Colors.blue,
                ),
                _buildEnhancedWeatherDetailBox(
                  "Wind Speed",
                  "${weatherData?.windSpeed?.toStringAsFixed(1) ?? '--'} m/s",
                  Icons.air,
                  Colors.green,
                ),
                _buildEnhancedWeatherDetailBox(
                  "Pressure",
                  "${weatherData?.pressure?.toStringAsFixed(0) ?? '--'} hPa",
                  Icons.compress,
                  Colors.purple,
                ),
              ],
            ),

            const SizedBox(height: 25),

            // Enhanced Flip Hint
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
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
                    size: 18,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    "Tap for clothing advice",
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.9),
                      fontSize: 13,
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

  Widget _buildEnhancedWeatherDetailBox(
    String label,
    String value,
    IconData icon,
    Color iconColor,
  ) {
    return Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(18),
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
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: iconColor, size: 24),
          ),
          const SizedBox(height: 10),
          Text(
            value,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: Colors.white.withValues(alpha: 0.7),
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildEnhancedClothingCard() {
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
        padding: const EdgeInsets.all(25),
        child: Column(
          children: [
            // Enhanced Header
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.checkroom, color: Colors.white, size: 28),
                  const SizedBox(width: 12),
                  const Text(
                    "What to Wear",
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            // Clothing Recommendations
            if (clothingRecommendation != null) ...[
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      _buildEnhancedClothingItem(
                        "Top",
                        clothingRecommendation!.topWear,
                        Icons.person,
                        Colors.blue,
                      ),
                      _buildEnhancedClothingItem(
                        "Bottom",
                        clothingRecommendation!.bottomWear,
                        Icons.man,
                        Colors.green,
                      ),
                      _buildEnhancedClothingItem(
                        "Footwear",
                        clothingRecommendation!.footwear,
                        Icons.directions_walk,
                        Colors.orange,
                      ),

                      const SizedBox(height: 20),

                      // Enhanced Quick Indicators
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          _buildEnhancedIndicator(
                            clothingRecommendation!.carryUmbrella
                                ? Icons.umbrella
                                : Icons.wb_sunny,
                            clothingRecommendation!.carryUmbrella
                                ? "Umbrella"
                                : "No Rain",
                            clothingRecommendation!.carryUmbrella
                                ? Colors.blue
                                : Colors.orange,
                          ),
                          _buildEnhancedIndicator(
                            clothingRecommendation!.carryJacket
                                ? Icons.layers
                                : Icons.air,
                            clothingRecommendation!.carryJacket
                                ? "Jacket"
                                : "No Jacket",
                            clothingRecommendation!.carryJacket
                                ? Colors.brown
                                : Colors.green,
                          ),
                        ],
                      ),

                      const SizedBox(height: 15),

                      // Enhanced Overall Advice
                      if (clothingRecommendation!.overallAdvice.isNotEmpty)
                        Container(
                          padding: const EdgeInsets.all(15),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(15),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.3),
                            ),
                          ),
                          child: Column(
                            children: [
                              const Icon(
                                Icons.lightbulb,
                                color: Colors.yellow,
                                size: 20,
                              ),
                              const SizedBox(height: 8),
                              Text(
                                clothingRecommendation!.overallAdvice,
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.9),
                                  fontSize: 14,
                                  height: 1.4,
                                ),
                                textAlign: TextAlign.center,
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ] else ...[
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const CircularProgressIndicator(
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        "Loading clothing recommendations...",
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.7),
                          fontSize: 16,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],

            const SizedBox(height: 15),

            // Enhanced Back Hint
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
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
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    "Tap to go back",
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.9),
                      fontSize: 13,
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

  Widget _buildEnhancedClothingItem(
    String category,
    String item,
    IconData icon,
    Color iconColor,
  ) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: iconColor, size: 20),
          ),
          const SizedBox(width: 15),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  category,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.7),
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  item,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
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

  Widget _buildEnhancedIndicator(IconData icon, String label, Color color) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: color, size: 24),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.8),
              fontSize: 12,
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
      // Extract JSON from AI response
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

    // Fallback if parsing fails
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
